## Table of Contents

- [Introduction](#download-a-linux-distro)
- [Pre-requisite](#pre-requisite)
- [Step 1: Prepare each node](#step-1-prepare-each-node)
- [Step 2: Initiate Kubernetes cluster (control node only)](#step-2-initiate-kubernetes-cluster-control-node-only)
- [Step 3: Joining worker nodes to cluster (worker nodes only)](#step-3-joining-worker-nodes-to-cluster-worker-nodes-only)
- [Step 4: Test cluster access (control node only)](#step-4-test-cluster-access-control-node-only)
- [Step 5: Optional settings (control node only)](#step-5-optional-settings-control-node-only)
- [Conclusion](#conclusion)
- [Extra: Scripts](#extra-scripts)

## Introduction 🐚
I created this article to document how to create a simple web deployment, utilizing Node.js and MongoDB. 
The objective is to showcase the relationship between Kubernetes resources, primarily service and deployment. The Node.js will act as the front-end of the application, interfacing with incoming traffic and MongoDB is the backend. 

## Pre-requisite 🍣

The following tools, aside from a running Kubernetes cluster, must be installed on the machine running the commands. Normally this will be the master or control node.
If you are using jumpbox, then they are installed on the jumpbox itself. 

+ Docker
+ Helm

