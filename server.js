console.log("--- NODE SERVER STARTING ---");
const express = require('express');
const bodyParser = require('body-parser');
const path = require('path');
const { QueueClient } = require("@azure/storage-queue");
const { BlobServiceClient, StorageSharedKeyCredential } = require("@azure/storage-blob");

const app = express();
const port = process.env.PORT || 3000;

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
    console.error("CRITICAL: Failed to initialize Azure Storage clients.", err.message);
}

// Middleware
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// API Endpoint: Health Check
app.get('/api/health', (req, res) => {
    res.json({
        nodeVersion: process.version,
        envVariableFound: !!process.env.AZURE_STORAGE_CONNECTION_STRING,
        queueClientInitialized: !!queueClient,
        blobClientInitialized: !!blobServiceClient,
        timestamp: new Date().toISOString()
    });
});

// API Endpoint: Get list of reports
app.get('/api/reports', async (req, res) => {
    if (!blobServiceClient) return res.status(500).json({ message: 'Storage not configured.' });
    try {
        const containerClient = blobServiceClient.getContainerClient(containerName);
        const reports = [];
        for await (const blob of containerClient.listBlobsFlat()) {
            reports.push({ name: blob.name, createdOn: blob.properties.createdOn, size: blob.properties.contentLength });
        }
        reports.sort((a, b) => b.createdOn - a.createdOn);
        res.status(200).json(reports);
    } catch (err) {
        res.status(500).json({ message: 'Failed to list reports.', error: err.message });
    }
});

// FIXED API Endpoint: Proxy Download
// This downloads the file to the Web App server first, then sends it to the user.
// This bypasses the Storage Firewall for the end-user.
app.get('/api/download-report/:name', async (req, res) => {
    const blobName = req.params.name;
    if (!blobServiceClient) return res.status(500).send("Storage not configured.");

    try {
        const containerClient = blobServiceClient.getContainerClient(containerName);
        const blobClient = containerClient.getBlobClient(blobName);

        console.log(`Proxying download for: ${blobName}`);
        const downloadResponse = await blobClient.download();
        
        // Set headers to tell the browser it's a file download
        res.setHeader('Content-Disposition', `attachment; filename="${blobName}"`);
        res.setHeader('Content-Type', 'text/csv');

        // Stream the file from Azure to the user's browser
        downloadResponse.readableStreamBody.pipe(res);
    } catch (err) {
        console.error("Download Error:", err.message);
        res.status(500).send("Failed to download file. " + err.message);
    }
});

// API Endpoint: Get status
app.get('/api/status/:id', async (req, res) => {
    const requestId = req.params.id;
    if (!blobServiceClient) return res.status(500).send("Storage not configured.");
    try {
        const containerClient = blobServiceClient.getContainerClient("status");
        const blobClient = containerClient.getBlobClient(`${requestId}.json`);
        if (!(await blobClient.exists())) return res.json({ status: 'Pending', message: 'Waiting for Jump Server...' });
        
        const downloadResponse = await blobClient.download();
        const body = await streamToBuffer(downloadResponse.readableStreamBody);
        const content = body.toString('utf8');
        try {
            res.json(JSON.parse(content.trim()));
        } catch (e) {
            res.json({ status: 'Processing', message: 'Jump Server is updating status...' });
        }
    } catch (err) {
        res.status(500).json({ status: 'Error', error: err.message });
    }
});

async function streamToBuffer(readableStream) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        readableStream.on("data", (data) => chunks.push(data instanceof Buffer ? data : Buffer.from(data)));
        readableStream.on("end", () => resolve(Buffer.concat(chunks)));
        readableStream.on("error", reject);
    });
}

app.post('/api/submit-groups', async (req, res) => {
    const { groupNames } = req.body;
    const requestId = `req-${Date.now()}`;
    if (!groupNames || !queueClient) return res.status(400).json({ message: 'Invalid request.' });
    try {
        const messageObj = { requestId, groupNames };
        const base64Message = Buffer.from(JSON.stringify(messageObj)).toString('base64');
        await queueClient.sendMessage(base64Message);
        res.status(200).json({ message: 'Request submitted!', requestId });
    } catch (err) {
        res.status(500).json({ message: 'Queue error.', error: err.message });
    }
});

app.get('*', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));
app.listen(port, () => console.log(`Server is running on port ${port}`));
