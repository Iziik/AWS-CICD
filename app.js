const express = require('express');
const app = express();
const PORT = process.env.PORT || 3001;

// Simple home page
app.get('/', (req, res) => {
  res.send(`
    <h1>🚀 My AWS DevOps Web App</h1>
    <p>This app was deployed automatically to AWS ECS!</p>
    <p>Environment: ${process.env.ENVIRONMENT || 'development'}</p>
    <p>Current time: ${new Date().toLocaleString()}</p>
    <p>Container ID: ${require('os').hostname()}</p>
  `);
});

// Health check endpoint (important for ECS)
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    time: new Date(),
    environment: process.env.ENVIRONMENT || 'development'
  });
});

// Simple API endpoint
app.get('/api/info', (req, res) => {
  res.json({
    app: 'my-aws-webapp',
    version: '1.0.0',
    environment: process.env.ENVIRONMENT || 'development',
    timestamp: new Date()
  });
});

app.listen(PORT, () => {
  console.log(`App running on port ${PORT}`);
  console.log(`Environment: ${process.env.ENVIRONMENT || 'development'}`);
});