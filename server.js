console.log("--- NODE SERVER STARTING ---");
const express = require('express');
const bodyParser = require('body-parser');
const path = require('path');
const { QueueClient } = require("@azure/storage-queue");
const { BlobServiceClient, generateBlobSASQueryParameters, BlobSASPermissions, StorageSharedKeyCredential } = require("@azure/storage-blob");

const app = express();
const port = process.env.PORT || 3000;

console.log("Environment check: PORT =", port);
console.log("Environment check: CONNECTION_STRING present =", !!process.env.AZURE_STORAGE_CONNECTION_STRING);

// Azure Storage Configuration
const connectionString = process.env.AZURE_STORAGE_CONNECTION_STRING;
const queueName = "group-requests";
const containerName = "reports";

let queueClient = null;
let blobServiceClient = null;

try {
    if (connectionString) {
        queueClient = new QueueClient(connectionString, queueName);
        blobServiceClient = BlobServiceClient.fromConnectionString(connectionString);
        console.log(`Storage clients initialized for: Queue(${queueName}) and Blob(${containerName})`);
    } else {
        console.warn("WARNING: AZURE_STORAGE_CONNECTION_STRING environment variable is not set.");
    }
} catch (err) {
    console.error("CRITICAL: Failed to initialize Azure Storage clients. Check your connection string format.", err.message);
}

// Middleware
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// API Endpoint: Health Check (Diagnostic)
app.get('/api/health', (req, res) => {
    const health = {
        nodeVersion: process.version,
        envVariableFound: !!process.env.AZURE_STORAGE_CONNECTION_STRING,
        queueClientInitialized: !!queueClient,
        blobClientInitialized: !!blobServiceClient,
        timestamp: new Date().toISOString()
    };
    res.json(health);
});

// API Endpoint: Get list of reports
app.get('/api/reports', async (req, res) => {
    if (!blobServiceClient) {
        return res.status(500).json({ message: 'Azure Storage is not configured.' });
    }

    try {
        const containerClient = blobServiceClient.getContainerClient(containerName);
        const reports = [];

        // List all blobs in the container
        for await (const blob of containerClient.listBlobsFlat()) {
            reports.push({
                name: blob.name,
                createdOn: blob.properties.createdOn,
                size: blob.properties.contentLength
            });
        }

        // Sort by newest first
        reports.sort((a, b) => b.createdOn - a.createdOn);
        res.status(200).json(reports);
    } catch (err) {
        console.error("Failed to list blobs:", err.message);
        res.status(500).json({ message: 'Failed to retrieve reports.' });
    }
});

// API Endpoint: Generate download link (SAS URL)
app.get('/api/download-report/:name', async (req, res) => {
    const blobName = req.params.name;
    if (!blobServiceClient) return res.status(500).send("Storage not configured.");

    try {
        const containerClient = blobServiceClient.getContainerClient(containerName);
        const blobClient = containerClient.getBlobClient(blobName);

        // Generate a SAS URL valid for 10 minutes
        const expiresOn = new Date(new Date().valueOf() + 10 * 60 * 1000);
        
        // Extract account name and key from connection string for SAS generation
        const parts = connectionString.split(';');
        const accountName = parts.find(p => p.startsWith('AccountName=')).split('=')[1];
        const accountKey = parts.find(p => p.startsWith('AccountKey=')).split('=')[1];
        const sharedKeyCredential = new StorageSharedKeyCredential(accountName, accountKey);

        const sasUrl = await blobClient.generateSasUrl({
            permissions: BlobSASPermissions.parse("r"), // Read only
            expiresOn: expiresOn
        });

        res.json({ url: sasUrl });
    } catch (err) {
        console.error("Failed to generate SAS URL:", err.message);
        res.status(500).json({ message: 'Failed to generate download link.' });
    }
});

// API Endpoint: Get status of a specific request
app.get('/api/status/:id', async (req, res) => {
    const requestId = req.params.id;
    if (!blobServiceClient) return res.status(500).send("Storage not configured.");

    try {
        const containerClient = blobServiceClient.getContainerClient("status");
        const blobClient = containerClient.getBlobClient(`${requestId}.json`);
        
        if (!(await blobClient.exists())) {
            return res.json({ status: 'Pending', message: 'Waiting for Jump Server to pick up request...' });
        }

        const downloadResponse = await blobClient.download();
        const body = await streamToBuffer(downloadResponse.readableStreamBody);
        const statusData = JSON.parse(body.toString());
        
        res.json(statusData);
    } catch (err) {
        res.status(500).json({ status: 'Error', message: 'Failed to fetch status.' });
    }
});

// Helper to read blob content
async function streamToBuffer(readableStream) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        readableStream.on("data", (data) => chunks.push(data instanceof Buffer ? data : Buffer.from(data)));
        readableStream.on("end", () => resolve(Buffer.concat(chunks)));
        readableStream.on("error", reject);
    });
}

// API Endpoint to receive group names
app.post('/api/submit-groups', async (req, res) => {
    const { groupNames } = req.body;
    const requestId = `req-${Date.now()}`; // Unique ID for tracking

    if (!groupNames) {
        return res.status(400).json({ message: 'No group names provided.' });
    }

    if (!queueClient) {
        return res.status(500).json({ message: 'Azure Storage Queue is not configured.' });
    }

    try {
        // Send as a JSON object instead of just a string
        const messageObj = { requestId, groupNames };
        const base64Message = Buffer.from(JSON.stringify(messageObj)).toString('base64');
        await queueClient.sendMessage(base64Message);
        
        res.status(200).json({ 
            message: 'Request submitted successfully!',
            requestId: requestId
        });
    } catch (err) {
        console.error("--- QUEUE SUBMISSION ERROR ---");
        console.error("Error Message:", err.message);
        console.error("Error Code:", err.code || "N/A");
        res.status(500).json({ message: 'Failed to process request.' });
    }
});

// Serve the index.html for any other requests
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(port, () => {
    console.log(`Server is running on port ${port}`);
});
