const express = require('express');
const bodyParser = require('body-parser');
const path = require('path');
const { QueueClient } = require("@azure/storage-queue");

const app = express();
const port = process.env.PORT || 3000;

// Azure Storage Queue Configuration
const connectionString = process.env.AZURE_STORAGE_CONNECTION_STRING;
const queueName = "group-requests";
let queueClient = null;

if (connectionString) {
    queueClient = new QueueClient(connectionString, queueName);
    console.log(`Queue client initialized for: ${queueName}`);
} else {
    console.warn("WARNING: AZURE_STORAGE_CONNECTION_STRING environment variable is not set. Queue submission will fail.");
}

// Middleware
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// API Endpoint to receive group names
app.post('/api/submit-groups', async (req, res) => {
    const { groupNames } = req.body;

    if (!groupNames) {
        return res.status(400).json({ message: 'No group names provided.' });
    }

    console.log(`Received group retrieval request for: ${groupNames}`);

    if (!queueClient) {
        return res.status(500).json({ message: 'Azure Storage Queue is not configured.' });
    }

    try {
        // Encode message to Base64 (required by Azure Storage Queue)
        const base64Message = Buffer.from(groupNames).toString('base64');
        await queueClient.sendMessage(base64Message);
        
        console.log(`Successfully pushed to queue: ${groupNames}`);
        res.status(200).json({ 
            message: 'Request submitted successfully to the processing queue.',
            received: groupNames
        });
    } catch (err) {
        console.error("Failed to push message to Azure Queue:", err.message);
        res.status(500).json({ message: 'Failed to process request. Please check Azure configuration.' });
    }
});

// Serve the index.html for any other requests
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(port, () => {
    console.log(`Server is running on port ${port}`);
});
