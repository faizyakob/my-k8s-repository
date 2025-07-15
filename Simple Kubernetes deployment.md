## Table of Contents

- [Introduction](#download-a-linux-distro)
- [Pre-requisite](#pre-requisite)
- [Step 1: Create source code files](#step-1-create-source-code-files)
- [Step 2: Helm deployment](#step-2-helm-deployment)
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

## Step 1: Create source code files 🍣

+ Create a dedicated directory, for example: <code style="color : red">/node-mongo-demo</code>.
  
  ```
  mkdir -p /node-mongo-demo
  cd /node-mongo-demo
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
+ Create a file named _package.json_ with below content.
  ```
  {
  "name": "node-mongo-demo",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "mongoose": "^7.0.0"
  }
  }
  ```
+ Create a _Dockerfile_.
  ```
  FROM node:18-alpine

  WORKDIR /app
  COPY package*.json ./
  RUN npm install
  COPY . .

  EXPOSE 3000
  CMD ["npm", "start"]
  ```
+ Build the new image using the _Dockerfile_.
  > You will have to login to Docker first before pushing your image.

  Once built, push the image to your Docker Hub repository. 🐳
  
  ```
  # Login to Docker Hub
  docker login

  # Build the image
  docker build -t stingray13/node-mongo-demo:latest .

  # Push the image
  docker push stingray13/node-mongo-demo:latest
  ```
+ You can verify using Docker Hub to ensure image successfully uploaded.
  
  <img width="921" height="448" alt="image" src="https://github.com/user-attachments/assets/88c324a5-eaa8-4fa9-b5be-fc17c7c9e66a" />

## Step 2: Helm deployment 🍣
> Note: You can also manually deploy all YAML files in this section manually, but we want to demonstrate how Helm can simplify the task.

+ Create a new folder, for example: <code style="color : red">/helm-node-mongo</code>. Create sub-folder <code style="color : red">templates</code> to host _mongo-deployment.yaml_, _mongo-service.yaml_, _web-deployment.yaml_ and _web-service.yaml_.
  
  ```
  mkdir -p /helm-node-mongo
  cd /helm-node-mongo
  ```

  At the end of this step, we should have something like this:
  ```
  helm-node-mongo/
  ├── Chart.yaml
  ├── values.yaml
  ├── templates/
  │   ├── mongo-deployment.yaml
  │   ├── mongo-service.yaml
  │   ├── web-deployment.yaml
  │   └── web-service.yaml
  ```

  The content of each file is as follows:

    + _Chart.yaml_
      
      ```
      apiVersion: v2
      name: node-mongo
      version: 0.1.0
      description: A simple Node.js + MongoDB app on Kubernetes
      ```

    + _values.yaml_
      
      ```
      web:
        image: faizyakob/node-mongo-demo
        tag: latest
        port: 3000

      mongo:
        user: admin
        password: admin123
        port: 27017
      ```
      
    + _templates/mongo-deployment.yaml_
 
      ```
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: mongo
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: mongo
        template:
          metadata:
            labels:
              app: mongo
        spec:
          containers:
          - name: mongo
            image: mongo:5
            ports:
            - containerPort: {{ .Values.mongo.port }}
            env:
            - name: MONGO_INITDB_ROOT_USERNAME
              value: {{ .Values.mongo.user }}
            - name: MONGO_INITDB_ROOT_PASSWORD
              value: {{ .Values.mongo.password }}
            volumeMounts:
            - name: mongo-data
              mountPath: /data/db
          volumes:
          - name: mongo-data
            emptyDir: {}
      ```
      
    + _templates/mongo-service.yaml_
      
      ```
      apiVersion: v1
      kind: Service
      metadata:
        name: mongo
      spec:
        ports:
        - port: {{ .Values.mongo.port }}
      selector:
        app: mongo
      ```

    + _templates/web-deployment.yaml_
 
      ```
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: node-web
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: node-web
      template:
        metadata:
          labels:
            app: node-web
        spec:
          containers:
          - name: node-web
              image: {{ .Values.web.image }}:{{ .Values.web.tag }}
              ports:
              - containerPort: {{ .Values.web.port }}
              env:
              - name: MONGO_URL
                value: mongodb://{{ .Values.mongo.user }}:{{ .Values.mongo.password }}@mongo:27017
      ```

    + _templates/web-service.yaml_

      ```
      apiVersion: v1
      kind: Service
      metadata:
        name: node-web
      spec:
        type: NodePort
        ports:
        - port: 80
          targetPort: {{ .Values.web.port }}
          nodePort: 30080
        selector:
        app: node-web
      ```

      
  

