const express = require('express');
const bodyParser = require('body-parser');
const path = require('path');

const app = express();
const port = process.env.PORT || 3000;

// Middleware
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, 'public')));

// API Endpoint to receive group names
app.post('/api/submit-groups', (req, res) => {
    const { groupNames } = req.body;

    if (!groupNames) {
        return res.status(400).json({ message: 'No group names provided.' });
    }

    console.log(`Received group retrieval request for: ${groupNames}`);

    // TODO: In a production environment, push this message to an Azure Storage Queue
    // so the Jump Server can poll and process it.
    
    res.status(200).json({ 
        message: 'Request received successfully.',
        received: groupNames
    });
});

// Serve the index.html for any other requests
app.get('*', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(port, () => {
    console.log(`Server is running on port ${port}`);
});
