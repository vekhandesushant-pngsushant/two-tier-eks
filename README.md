# Two-Tier Application on AWS EKS
### Git + Jenkins + Docker + Kubernetes (EKS)

A complete CI/CD project that deploys a **two-tier application** to Amazon EKS:

| Tier | Technology | Kubernetes object |
|---|---|---|
| Tier 1: Web/App | Node.js (Express) | Deployment + LoadBalancer Service + HPA |
| Tier 2: Database | MySQL 8 | StatefulSet + headless Service + EBS volume (PVC) |

**Region used:** `ap-south-1` (Mumbai) | **Cluster name:** `two-tier-eks` | **Namespace:** `two-tier`

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [How the CI/CD flow works](#2-how-the-cicd-flow-works)
3. [Folder structure](#3-folder-structure)
4. [Prerequisites](#4-prerequisites)
5. [Step-by-step setup](#5-step-by-step-setup)
6. [The Jenkins pipeline explained](#6-the-jenkins-pipeline-explained)
7. [Verify and demonstrate the project](#7-verify-and-demonstrate-the-project)
8. [Cleanup (important: avoid AWS charges)](#8-cleanup-important-avoid-aws-charges)
9. [Troubleshooting](#9-troubleshooting)
10. [Production hardening ideas](#10-production-hardening-ideas)

---

## 1. Architecture

```
                          Developer (git push)
                                  |
                                  v
                       +---------------------+
                       |   GitHub (Git repo) |
                       +----------+----------+
                                  | webhook
                                  v
                       +---------------------+          +-------------------+
                       |  Jenkins (EC2)      |--push--->|  Amazon ECR       |
                       |  test > build >     |          |  two-tier-app     |
                       |  push > deploy      |          |  two-tier-db      |
                       +----------+----------+          +---------+---------+
                                  | kubectl apply                 | image pull
                                  v                               |
 Internet --> AWS ELB (port 80) --+-------------------------------+
                  |
  +---------------|--------------------------------------------------+
  |  VPC          v                                                  |
  |  +--------- EKS Cluster: two-tier-eks (namespace: two-tier) ---+ |
  |  |                                                              | |
  |  |  TIER 1 (Web/App)                TIER 2 (Database)           | |
  |  |  Service web-app (LoadBalancer)  Service mysql (headless)    | |
  |  |     |                               |                        | |
  |  |  Deployment web-app (2-5 pods)   StatefulSet mysql (1 pod)   | |
  |  |  Node.js + Express  ---SQL:3306-->  MySQL 8                  | |
  |  |  HPA (CPU 70%)                      |                        | |
  |  |                                  PVC 10Gi (gp3)              | |
  |  +------------------------------------|-------------------------+ |
  |                                    EBS volume                      |
  +--------------------------------------------------------------------+
```

| Component | Purpose |
|---|---|
| Git / GitHub | Source code and version history |
| Jenkins | CI/CD automation: test, build, push, deploy |
| Docker | Packages each tier into a container image |
| Amazon ECR | Private registry that stores the Docker images |
| Amazon EKS | Managed Kubernetes cluster |
| Deployment | Runs the stateless app pods and handles rolling updates |
| StatefulSet + PVC | Runs the database with a persistent disk, so data survives pod restarts |
| ELB | Public entry point that distributes traffic across app pods |
| HPA | Automatically scales app pods between 2 and 5 based on CPU |

---

## 2. How the CI/CD flow works

1. A developer pushes code to GitHub.
2. A GitHub webhook notifies Jenkins.
3. Jenkins pulls the code and runs the unit tests.
4. Jenkins builds two Docker images (app and database).
5. Jenkins pushes both images to Amazon ECR.
6. Jenkins connects to EKS and applies the Kubernetes manifests with the new image tags.
7. Kubernetes performs a zero-downtime rolling update.
8. A smoke test confirms the application is healthy. If the deployment fails, Jenkins rolls back automatically.

---

## 3. Folder structure

```
two-tier-eks/
|-- app/                          # TIER 1 - Node.js
|   |-- src/server.js             #   Express API + health endpoints
|   |-- src/db.js                 #   MySQL connection pool
|   |-- src/validate.js           #   Input validation (unit-tested)
|   |-- public/index.html         #   Simple web UI
|   |-- test/validate.test.js     #   Unit tests
|   |-- package.json
|   |-- Dockerfile                #   Multi-stage build, non-root user
|   `-- .dockerignore
|-- db/                           # TIER 2 - MySQL
|   |-- Dockerfile                #   mysql:8.0 + init script
|   `-- init.sql                  #   Creates the `tasks` table and sample rows
|-- k8s/                          # Kubernetes manifests
|   |-- 00-namespace.yaml
|   |-- 01-storageclass-gp3.yaml
|   |-- 02-secret.example.yaml    #   TEMPLATE only - contains no real passwords
|   |-- 03-mysql-service.yaml
|   |-- 04-mysql-statefulset.yaml
|   |-- 05-app-configmap.yaml
|   |-- 06-app-deployment.yaml
|   |-- 07-app-service.yaml
|   |-- 08-app-hpa.yaml
|   `-- optional/networkpolicy.yaml
|-- eksctl/cluster.yaml           # EKS cluster definition
|-- scripts/
|   |-- install-jenkins-ubuntu.sh # Installs Jenkins, Docker, AWS CLI, kubectl, eksctl
|   |-- create-ecr.sh             # Creates the two ECR repositories
|   `-- create-secret.sh          # Creates the MySQL secret (kept out of Git)
|-- docs/architecture.md
|-- docker-compose.yml            # Local testing
|-- Jenkinsfile                   # CI/CD pipeline
`-- .gitignore
```

### Application endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | Web UI |
| `GET /api/tasks` | List tasks |
| `POST /api/tasks` | Add a task (`{"title": "..."}`) |
| `DELETE /api/tasks/:id` | Delete a task |
| `GET /api/info` | Shows which pod served the request and the app version |
| `GET /health` | Liveness probe (process is alive) |
| `GET /health/ready` | Readiness probe (database is reachable) |

---

## 4. Prerequisites

- An AWS account.
- A GitHub account.
- An **IAM user** with enough permissions to create EKS clusters (EKS, EC2, VPC, CloudFormation, IAM, ECR). This guide calls it `eks-admin`. Its access keys are configured on the Jenkins server with `aws configure`.
- An **IAM role for the Jenkins EC2 instance** (this guide calls it `Ec2_role`). Jenkins uses this role automatically.
- A local machine or EC2 instance with `git`, `docker`, `aws`, `kubectl` and `eksctl`. The script `scripts/install-jenkins-ubuntu.sh` installs all of them on Ubuntu.

> **Cost warning:** While the project is running you are billed for the EKS control plane (about $0.10/hour), two t3.medium nodes, a NAT Gateway, an ELB, an EBS volume and the Jenkins EC2 instance. Always finish with [Section 8 (Cleanup)](#8-cleanup-important-avoid-aws-charges).

### Two different identities (important to understand)

| Who | Identity used | Where it comes from |
|---|---|---|
| You, typing commands in the terminal (`eksctl`, `kubectl`, `aws`) | IAM user `eks-admin` | `aws configure` (`~/.aws/credentials`) |
| Jenkins pipeline (runs as the `jenkins` Linux user) | IAM role `Ec2_role` | The role attached to the EC2 instance |

Because the cluster is created by `eks-admin`, only `eks-admin` can use it at first. Jenkins uses a different identity, so you must grant it access explicitly (Step 9).

Check which identity you are using at any time:

```bash
aws sts get-caller-identity                 # you
sudo -u jenkins aws sts get-caller-identity # Jenkins
```

---

## 5. Step-by-step setup

### Step 1: Test locally with Docker Compose

```bash
cd two-tier-eks
docker compose up --build
# open http://localhost:3000
docker compose down -v      # stop and clean up
```

Compose starts MySQL first, waits until it is healthy, then starts the Node.js app. If it works here, it will work on Kubernetes.

### Step 2: Prepare the Jenkins server (Ubuntu EC2)

1. Launch an **Ubuntu 22.04 EC2 instance**: `t3.medium`, 20 GB disk, region `ap-south-1`.
2. Security group: allow port **22** and **8080** from **your IP only**.
3. Attach the IAM role (`Ec2_role`) to the instance.
4. SSH into the instance and run:

```bash
git clone https://github.com/<your-user>/two-tier-eks.git
cd two-tier-eks
chmod +x scripts/*.sh
./scripts/install-jenkins-ubuntu.sh
```

The script installs Jenkins, Docker, AWS CLI v2, kubectl and eksctl, and prints the Jenkins initial admin password.

5. Open `http://<EC2-PUBLIC-IP>:8080`, paste the password, choose **Install suggested plugins**, and create an admin user.

> **Note:** The public IP changes every time you stop and start the instance (unless you attach an Elastic IP). Use the new IP afterwards.

### Step 3: Give your Linux user permission to use Docker

If `docker ps` shows `permission denied while trying to connect to the docker API`:

```bash
sudo usermod -aG docker $USER
newgrp docker              # or log out and SSH in again
docker ps                  # should print an empty table
```

Jenkins needs the same permission:

```bash
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
sudo -u jenkins docker ps
```

### Step 4: Configure AWS CLI and find your Account ID

```bash
aws configure                 # access key, secret key, region = ap-south-1
aws sts get-caller-identity   # note the 12-digit "Account" value
```

### Step 5: Add the Jenkins role permissions

The role attached to the Jenkins EC2 instance needs two permissions: push images to ECR and read EKS cluster details. Run these with an admin identity (or add them in the IAM console):

```bash
ROLE=Ec2_role     # use your role name; note there are NO spaces around "="

aws iam attach-role-policy --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam put-role-policy --role-name $ROLE --policy-name eks-describe \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["eks:DescribeCluster","eks:ListClusters"],"Resource":"*"}]}'

aws iam list-attached-role-policies --role-name $ROLE
aws iam list-role-policies --role-name $ROLE
```

SSM and CloudWatch policies on the same role are harmless but are not used by this project.

### Step 6: Create the EKS cluster

Run this inside `tmux` so that the cluster creation continues even if your SSH connection drops:

```bash
cd ~/two-tier-eks
tmux new -s eks
eksctl create cluster -f eksctl/cluster.yaml      # takes 15 to 20 minutes
```

If your SSH session drops, reconnect and run `tmux attach -t eks`.

When it finishes:

```bash
kubectl get nodes                  # 2 nodes in Ready state
kubectl get pods -n kube-system    # coredns, ebs-csi, metrics-server Running
```

The cluster configuration creates a VPC, the EKS control plane, a managed node group (2 x t3.medium) and these add-ons: `aws-ebs-csi-driver` (disks for MySQL) and `metrics-server` (needed by the HPA).

You can create the ECR repositories (Step 7) in a second tmux window while the cluster is being built.

### Step 7: Create the ECR repositories

```bash
./scripts/create-ecr.sh
aws ecr describe-repositories --region ap-south-1 --query "repositories[].repositoryName"
```

You should see `two-tier-app` and `two-tier-db`. The script is safe to run more than once.

### Step 8: Create the database secret (once, before the first deploy)

```bash
./scripts/create-secret.sh
kubectl -n two-tier get secret mysql-secret       # DATA column should show 4
```

To choose your own passwords:

```bash
MYSQL_ROOT_PASSWORD='...' MYSQL_PASSWORD='...' ./scripts/create-secret.sh
```

Passwords live only inside the cluster and never in Git. Jenkins checks that the secret exists before deploying.

> **Important:** MySQL creates its users and passwords only the first time it starts on an empty data volume. Changing the secret later does **not** change the password stored on the volume. Create the secret **before** the first deploy and do not change it afterwards. If you must reset it, delete the StatefulSet and the PVC (this deletes all database data), then deploy again:
> ```bash
> kubectl -n two-tier delete statefulset mysql
> kubectl -n two-tier delete pvc data-mysql-0
> ```

### Step 9: Give Jenkins access to the cluster

```bash
eksctl create iamidentitymapping --cluster two-tier-eks --region ap-south-1 \
  --arn arn:aws:iam::<ACCOUNT_ID>:role/Ec2_role \
  --username jenkins --group system:masters
```

Use the **role ARN** (not the `assumed-role/...` ARN). If your role has a path such as `/service-role/`, remove the path from the ARN.

Verify that Jenkins can reach the cluster:

```bash
sudo -u jenkins aws sts get-caller-identity                      # shows assumed-role/Ec2_role/...
sudo -u jenkins aws eks update-kubeconfig --name two-tier-eks --region ap-south-1
sudo -u jenkins kubectl get nodes                                # shows the 2 nodes
```

`system:masters` is convenient for a demo. In production use a narrower role and Kubernetes RBAC.

### Step 10: Put your Account ID in the Jenkinsfile and push to GitHub

The only value you must change in the project is `AWS_ACCOUNT_ID` in the `Jenkinsfile`:

```bash
sed -i "s/123456789012/<ACCOUNT_ID>/" Jenkinsfile
grep AWS_ACCOUNT_ID Jenkinsfile
```

Do **not** edit the placeholders `ACCOUNT_ID`, `REGION`, `APP_IMAGE_TAG` and `DB_IMAGE_TAG` inside the `k8s/` files. The pipeline replaces them automatically.

Push everything to GitHub:

```bash
git init
git add .
git commit -m "Initial 2-tier EKS project"
git branch -M main
git remote add origin https://github.com/<your-user>/two-tier-eks.git
git push -u origin main
```

If GitHub asks for a password, use a **Personal Access Token**.

If you cloned the project and a script shows `Permission denied`, make the scripts executable and commit that change:

```bash
chmod +x scripts/*.sh
git add scripts/ && git commit -m "Make scripts executable" && git push
```

### Step 11: Create the Jenkins pipeline job

1. In Jenkins choose **New Item**, name it `two-tier-eks`, select **Multibranch Pipeline**.
2. Under **Branch Sources** add **Git** (or GitHub) and enter your repository URL. Add credentials if the repository is private.
3. Set **Script Path** to `Jenkinsfile`.
4. Save, then click **Scan Now**.

### Step 12: Set up the GitHub webhook (automatic builds)

1. In GitHub open the repository, then **Settings > Webhooks > Add webhook**.
2. Payload URL: `http://<JENKINS-PUBLIC-IP>:8080/github-webhook/`
3. Content type: `application/json`. Event: **Push**.

If Jenkins is not reachable from GitHub, use polling instead: set the job's trigger to `H/5 * * * *`.

### Step 13: Run the pipeline

Open the `main` branch in Jenkins and click **Build Now**. Watch the **Console Output**. After a successful build, get the public URL:

```bash
kubectl -n two-tier get pods,svc,pvc
kubectl -n two-tier get svc web-app        # EXTERNAL-IP column is your public URL
```

Open `http://<EXTERNAL-IP>` in a browser. A new load balancer can take 2 to 3 minutes before it responds.

---

## 6. The Jenkins pipeline explained

| Stage | What it does |
|---|---|
| **Checkout** | Pulls the code and computes the image tags |
| **Unit Test** | Runs `npm test` inside a temporary Node container |
| **Build Docker Images** | Builds the app image and the database image |
| **Push to ECR** | Logs in to ECR using the instance role and pushes the images |
| **Deploy to EKS** | Replaces the image placeholders, runs `kubectl apply`, waits for the rollout |
| **Smoke Test** | Polls `/health/ready` on the load balancer URL |
| **post: failure** | Runs `kubectl rollout undo` to return to the previous version |
| **post: always** | Cleans up unused Docker images |

**Image tagging**

- App image tag: `<build-number>-<git-sha>`, so every build gets a unique tag.
- Database image tag: a hash of the `db/` folder. MySQL restarts **only when `db/` changes**, so everyday app deployments never disturb the database.

**Deployment safety**

- Rolling update with `maxUnavailable: 0` gives zero downtime.
- The readiness probe sends traffic only to pods that can reach the database.
- The liveness probe restarts a pod only if the Node.js process itself is unhealthy.
- Resource requests and limits are set on both tiers.
- The application container runs as a non-root user.

---

## 7. Verify and demonstrate the project

### Check the application

```bash
curl http://<ELB-URL>/health/ready
curl http://<ELB-URL>/api/tasks
curl http://<ELB-URL>/api/info
```

Refresh the web page several times. The footer shows which pod served you, which demonstrates load balancing across the two pods.

### Demonstrate data persistence

```bash
kubectl -n two-tier delete pod mysql-0
kubectl -n two-tier get pods -w          # mysql-0 is recreated
# refresh the browser: the tasks are still there
```

The data survives because it is stored on an EBS volume (PVC), not inside the pod.

### Demonstrate self-healing

```bash
kubectl -n two-tier delete pod $(kubectl -n two-tier get pod -l app=web-app -o name | head -1)
kubectl -n two-tier get pods
```

The Deployment creates a replacement pod automatically.

### Demonstrate scaling and rollback

```bash
kubectl -n two-tier scale deployment web-app --replicas=3
kubectl -n two-tier rollout history deployment/web-app
kubectl -n two-tier rollout undo deployment/web-app
```

### Inspect logs and the database

```bash
kubectl -n two-tier logs deploy/web-app
kubectl -n two-tier get secret mysql-secret -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 -d
kubectl -n two-tier exec -it mysql-0 -- mysql -uappuser -p appdb -e "SELECT * FROM tasks;"
```

### Demonstrate the full CI/CD loop

Change the heading in `app/public/index.html`, then:

```bash
git add -A && git commit -m "Update heading" && git push
```

Jenkins starts a build automatically, and the `version` shown in the page footer changes after the rolling update. Do this test **before** your presentation so you know it works.

---

## 8. Cleanup (important: avoid AWS charges)

Follow this order exactly.

**1. Delete the application first (this removes the load balancer):**

```bash
kubectl delete ns two-tier
kubectl get ns                           # wait until two-tier is gone
```

**2. Delete the cluster with eksctl:**

```bash
eksctl delete cluster --name two-tier-eks --region ap-south-1 --wait
```

**3. Delete the ECR repositories:**

```bash
aws ecr delete-repository --repository-name two-tier-app --force --region ap-south-1
aws ecr delete-repository --repository-name two-tier-db  --force --region ap-south-1
```

**4. Delete leftover EBS volumes.** The StorageClass uses `reclaimPolicy: Retain`, so the MySQL volume remains after the cluster is gone. In the AWS console open **EC2 > Volumes** and delete volumes whose state is **Available**. Or by CLI:

```bash
aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available \
  --query "Volumes[].[VolumeId,Size]" --output table
aws ec2 delete-volume --volume-id vol-xxxxxxxx --region ap-south-1
```

**5. Stop or terminate the Jenkins EC2 instance.** *Stop* keeps your files and charges only for disk. *Terminate* deletes everything.

**6. Final check (region Mumbai):** EC2 (instances, volumes, load balancers, Elastic IPs), VPC (NAT gateways) and CloudFormation (no `eksctl-two-tier-eks-*` stacks).

```bash
aws cloudformation list-stacks --region ap-south-1 \
  --query "StackSummaries[?contains(StackName,'two-tier-eks') && StackStatus!='DELETE_COMPLETE'].[StackName,StackStatus]" \
  --output table
```

The output should be empty.

### Pausing instead of deleting

A cluster cannot be "stopped". You can scale the nodes to zero, which stops the node charges but keeps your data. The control plane and NAT Gateway still cost money.

```bash
eksctl scale nodegroup --cluster two-tier-eks --name workers --nodes 0 --nodes-min 0 --region ap-south-1
# resume later:
eksctl scale nodegroup --cluster two-tier-eks --name workers --nodes 2 --nodes-min 2 --region ap-south-1
```

> **Always delete the cluster with `eksctl delete cluster`.** Deleting the CloudFormation stacks by hand can leave the VPC stuck, because EKS creates a security group (`eks-cluster-sg-...`) that CloudFormation does not own.

---

## 9. Troubleshooting

| Problem | Likely cause and fix |
|---|---|
| `./scripts/xxx.sh: Permission denied` | `chmod +x scripts/*.sh` (or run with `bash scripts/xxx.sh`) |
| `docker ps`: `permission denied ... docker.sock` | `sudo usermod -aG docker $USER && newgrp docker`. For Jenkins: `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `ROLE= Ec2_role: command not found` | There must be no spaces around `=`. Write `ROLE=Ec2_role` |
| `eksctl create cluster`: `AlreadyExistsException: Stack ... already exists` | Leftover CloudFormation stacks from an earlier cluster. Delete the old cluster first (Section 8). If only stacks remain, delete the addon stacks first, then the cluster stack |
| Stack delete: `cannot be deleted while TerminationProtection is enabled` | `aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name <name> --region ap-south-1`, then delete again |
| Stack stuck in `DELETE_FAILED`: `The vpc ... has dependencies` | A resource outside CloudFormation remains in the VPC. List ENIs, load balancers and security groups in the VPC and delete them. The usual culprit is the `eks-cluster-sg-two-tier-eks-...` security group. Then delete the stack again |
| `aws sts get-caller-identity` shows `user/eks-admin` for Jenkins | Jenkins has its own old keys. Remove them: `sudo rm -rf /var/lib/jenkins/.aws` |
| `sudo -u jenkins aws ...`: `Unable to locate credentials` | The IAM role is not attached to the EC2 instance. EC2 > Instance > Actions > Security > Modify IAM role |
| Jenkins `kubectl`: `You must be logged in to the server (Unauthorized)` | Step 9 (`iamidentitymapping`) is missing for the Jenkins role |
| Push stage: `repository does not exist` | Wrong `AWS_ACCOUNT_ID` in the Jenkinsfile, or the ECR repositories were not created |
| Push stage: `no basic auth credentials` or `AccessDenied` | The Jenkins role is missing `AmazonEC2ContainerRegistryPowerUser` |
| Deploy stage: `mysql-secret missing` | Run `./scripts/create-secret.sh` (Step 8) |
| `mysql-0` stays `Pending` | `kubectl describe pvc -n two-tier`. The EBS CSI add-on or the StorageClass is missing |
| App pod `0/1 Ready` | The database is not ready or the secret is wrong. `kubectl logs deploy/web-app -n two-tier` |
| App log: `Access denied for user` | Secret passwords do not match the password stored on the MySQL volume (see the note in Step 8) |
| `ImagePullBackOff` | The image or tag is not in ECR, or the Account ID is wrong |
| `EXTERNAL-IP <pending>` | Wait 2 to 3 minutes for the load balancer |
| HPA shows `<unknown>` | `kubectl get deploy metrics-server -n kube-system` |
| Jenkins page does not open after restarting EC2 | The public IP changed. Use the new IP |

Useful commands for any problem:

```bash
kubectl -n two-tier get pods,svc,pvc,events
kubectl -n two-tier describe pod <pod-name>
kubectl -n two-tier logs <pod-name>
```

---

## 10. Production hardening ideas

- Use **Amazon RDS for MySQL** (Multi-AZ) instead of a single-pod StatefulSet.
- Use the **AWS Load Balancer Controller** with an ALB Ingress, an **ACM certificate** for HTTPS and a Route 53 domain.
- Store secrets in **AWS Secrets Manager** with the External Secrets Operator, and enable EKS secrets encryption with KMS.
- Apply the **NetworkPolicy** in `k8s/optional/networkpolicy.yaml` so that only app pods can reach MySQL.
- Add image scanning (for example Trivy) to the Jenkins pipeline.
- Replace `system:masters` with a narrower RBAC role for Jenkins.
- Use **Helm** or **Kustomize** for separate dev, staging and production environments.
- Run Jenkins agents as Kubernetes pods instead of a single EC2 server.
- Restrict ports 22 and 8080 to trusted IP addresses and put Jenkins behind HTTPS.