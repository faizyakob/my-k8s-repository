
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
