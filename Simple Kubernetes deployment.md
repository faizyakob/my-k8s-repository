## Table of Contents

- [Introduction](#download-a-linux-distro)
- [Pre-requisite](#pre-requisite)
- [Step 1: Build necessary files](#build-necessary-files)
- [Step 2: Initiate Kubernetes cluster (control node only)](#step-2-initiate-kubernetes-cluster-control-node-only)
- [Step 3: Joining worker nodes to cluster (worker nodes only)](#step-3-joining-worker-nodes-to-cluster-worker-nodes-only)
- [Step 4: Test cluster access (control node only)](#step-4-test-cluster-access-control-node-only)
- [Step 5: Optional settings (control node only)](#step-5-optional-settings-control-node-only)
- [Conclusion](#conclusion)
- [Extra: Scripts](#extra-scripts)

## Introduction 🐚
I created this article to document how to create a simple web app deployment, utilizing Node.js and MongoDB. 
The objective is to showcase the relationship between Kubernetes resources, primarily service and deployment. The Node.js will act as the front-end of the application, interfacing with incoming traffic and MongoDB is the backend. 

## Pre-requisite 🍣

The following tools, aside from a running Kubernetes cluster, must be installed on the machine running the commands. Normally this will be the master or control node.
If you are using jumpbox, then they are installed on the jumpbox itself. 

+ Docker
+ Helm

> The steps below assume _root_ user.

## Step 1: Build necessary files 🍣

+ Create a dedicated directory, for example: /node-mongo-demo.
  
  ```
  mkdir -p /node-mongo-demo
  ```
  We will house all source code files here.

+ Create a file named _server.js_ with below content. This is our Node.js web app code.
  ```
  const express = require('express');
  const mongoose = require('mongoose');

  const app = express();
  const port = 3000;
  const mongoUrl = process.env.MONGO_URL || 'mongodb://localhost:27017';

  mongoose.connect(mongoUrl, { useNewUrlParser: true, useUnifiedTopology: true })
    .then(() => console.log('✅ Connected to MongoDB'))
    .catch(err => console.error('❌ MongoDB connection error:', err));

  app.get('/', (req, res) => {
    res.send('<h1>Hello from Node.js App running on Kubernetes 🚀</h1>');
  });

  app.listen(port, () => {
    console.log(`🟢 Server running at http://localhost:${port}`);
  });
  ```

