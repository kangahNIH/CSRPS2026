const http = require('http');

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<h1>Success! Your Azure Web App is running.</h1><p>You can now start building your user interface here.</p>');
});

// Azure App Service provides the port to listen on via an environment variable
const port = process.env.PORT || 3000;
server.listen(port, () => {
  console.log(`Server is listening on port ${port}...`);
});

