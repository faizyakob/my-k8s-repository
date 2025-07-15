## Table of Contents

- [Introduction](#introduction)
- [Pre-requisite](#pre-requisite)
- [Step 1: Create source code files](#step-1-create-source-code-files)
- [Step 2: Helm deployment](#step-2-helm-deployment)
- [Step 3: Install the Chart](#step-3-install-the-chart)
- [Step 4: View the pods and services](#step-4-view-the-pods-and-services)
- [Step 5: Access the web app](#step-5-access-the-web-app)
- [Conclusion](#conclusion)
- [Extra: YAML files](#extra-yaml-files)

## Introduction
I created this article to document how to create a simple web app deployment, utilizing Node.js and MongoDB. 
The objective is to showcase the relationship between Kubernetes resources, primarily service and deployment. The Node.js will act as the front-end of the application, interfacing with incoming traffic and MongoDB is the backend. 

## Pre-requisite

The following tools, aside from a running Kubernetes cluster, must be installed on the machine running the commands. Normally this will be the master or control node.
If you are using jumpbox, then they are installed on the jumpbox itself. 

+ Docker
+ Helm

> The steps below assume _root_ user.

## Step 1: Create source code files

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

## Step 2: Helm deployment
> Note: You can also manually deploy all YAML files in this section manually, but we want to demonstrate how Helm can simplify the task.

+ 📕 Create a new folder, for example: <code style="color : red">/helm-node-mongo</code>. Create sub-folder <code style="color : red">templates</code> to host _mongo-deployment.yaml_, _mongo-service.yaml_, _web-deployment.yaml_ and _web-service.yaml_.
  
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

  <details>
  <summary>📃 Chart.yaml</summary><br>

    
      apiVersion: v2
      name: node-mongo
      version: 0.1.0
      description: A simple Node.js + MongoDB app on Kubernetes
     
  
  </details>

  <details>
  <summary>📃 values.yaml</summary><br>
      
      
      web:
        image: faizyakob/node-mongo-demo
        tag: latest
        port: 3000

      mongo:
        user: admin
        password: admin123
        port: 27017
 
  
  </details>
      
  <details>
  <summary>📃 templates/mongo-deployment.yaml</summary><br>
 
      
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
      
  
  </details>
  
  <details>
  <summary>📃 templates/mongo-service.yaml</summary><br>
      
      
      apiVersion: v1
      kind: Service
      metadata:
        name: mongo
      spec:
        ports:
        - port: {{ .Values.mongo.port }}
      selector:
        app: mongo
      
  
  </details>

  <details>
  <summary>📃 templates/web-deployment.yaml</summary><br>
 
     
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
     
  
  </details>

  <details>
  <summary>📃 templates/web-service.yaml</summary><br>

     
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
      
  
  </details>

## Step 3: Install the Chart
> Ensure you are in the same directory where _Chart.yaml_ is.

+ ⚓ Install the Helm chart (we give it the name "myapp"):

  ```
  helm install myapp .
  ```

  The command will display the status of the Helm chart.
  
  <img width="1192" height="302" alt="image" src="https://github.com/user-attachments/assets/cbe88087-79f6-4c44-a792-a4d12152c1df" />

+ Verify the Helm chart is successfully running:

  ```
  helm list
  ```

  <img width="2626" height="132" alt="image" src="https://github.com/user-attachments/assets/8152ea83-a83b-4b85-81ef-5aed168fc02a" />


## Step 4: View the pods and services

  🚀 View all the Kubernetes resources that are associated with the web app deployment:

  ```
  kubectl get pods -l 'app in (mongo,node-web)'
  kubectl get svc
  kubectl get deploy node-web
  kubectl get deploy mongo
  ```

  <img width="1678" height="654" alt="image" src="https://github.com/user-attachments/assets/b702b703-02d7-44c2-a9c9-fbdefc7f7548" />

## Step 5: Access the web app

Once eveything is in placed, you can query the localhost destination via the NodePort exposed port, 30080.

Either query using <code style="color : red">_curl_</code>, or access via web browser URL. 

🚀 It should return successful result. 

Using <code style="color : red">_curl_</code>:

  <img width="1938" height="90" alt="image" src="https://github.com/user-attachments/assets/3fe95536-6842-455e-acfd-9109e52e6409" />
  

Using web browser:

  <img width="1758" height="306" alt="image" src="https://github.com/user-attachments/assets/c0b356c6-370b-49d7-8d69-ab1c7821a324" />


## Conclusion

This section describe on high-level of the above web app deployment setup. 

In brief, we deployed 2 services and 2 deployments, each serving different section of the traffic flow. 

The front-end consists of **node-web service** and **node-web deployment**. 
The **node-web service** accepts incoming traffic via its exposed NodePort port, 30080 (or 30001) and distribute it to the pod of **node-web deployment**. We only have a sinle replica in this setup, but we can easily scale up the deployment.

The back-end consists of **mongo service** and **mongo deployment**. After being processed by the front-end, the node-web pod sends the traffic to **mongo service** using the URL defined in its container environment, and the **mongo service** distribute the traffic to pods of **mongo deployment**. Again, we only have a single replica for education purposes. 

Diagram below visualize the flow.

<img width="1536" height="1024" alt="External" src="https://github.com/user-attachments/assets/e06b7f36-21c1-4ee4-850f-01fc033c3222" />


## Extra: YAML files

All the YAML and source code files used in this tutorial are available at [ZIP](node-mongo-demo-helm.zip).



