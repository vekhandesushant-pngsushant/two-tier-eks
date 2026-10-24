# 2-Tier Application on AWS EKS (Git + Jenkins + Docker + Kubernetes)

**Tier 1:** Node.js (Express) web/app tier  **Tier 2:** MySQL 8 database tier
**Region:** `ap-south-1` (Mumbai)

> Language note: Every step is explained in **English + मराठी**.
> प्रत्येक step English आणि मराठी दोन्हीत समजावली आहे.

---

## 0. What you will build / तुम्ही काय बनवणार

Developer `git push` करतो → GitHub webhook Jenkins ला कळवतो → Jenkins unit test चालवतो → Docker images बनवतो →
ECR मध्ये push करतो → EKS cluster वर `kubectl apply` करतो → ELB च्या public URL वर app चालू होतो.

See `docs/architecture.md` for the diagram. / diagram साठी `docs/architecture.md` पहा.

## 1. Folder structure / फोल्डर रचना

```
two-tier-eks/
├── app/                          # TIER 1 - Node.js
│   ├── src/server.js             #   Express API + health endpoints
│   ├── src/db.js                 #   MySQL connection pool
│   ├── src/validate.js           #   input validation (unit-tested)
│   ├── public/index.html         #   simple UI
│   ├── test/validate.test.js     #   unit tests
│   ├── package.json
│   ├── Dockerfile                #   multi-stage, non-root
│   └── .dockerignore
├── db/                           # TIER 2 - MySQL
│   ├── Dockerfile                #   mysql:8.0 + init script
│   └── init.sql                  #   creates `tasks` table
├── k8s/                          # Kubernetes manifests
│   ├── 00-namespace.yaml
│   ├── 01-storageclass-gp3.yaml
│   ├── 02-secret.example.yaml    #   TEMPLATE only (no real passwords)
│   ├── 03-mysql-service.yaml
│   ├── 04-mysql-statefulset.yaml
│   ├── 05-app-configmap.yaml
│   ├── 06-app-deployment.yaml
│   ├── 07-app-service.yaml
│   ├── 08-app-hpa.yaml
│   └── optional/networkpolicy.yaml
├── eksctl/cluster.yaml           # EKS cluster definition
├── scripts/
│   ├── install-jenkins-ubuntu.sh # Jenkins+Docker+AWS CLI+kubectl+eksctl
│   ├── create-ecr.sh             # 2 ECR repos
│   └── create-secret.sh          # MySQL secret (kept out of Git)
├── docs/architecture.md
├── docker-compose.yml            # local test
├── Jenkinsfile                   # CI/CD pipeline
└── .gitignore
```

---

## 2. Prerequisites / पूर्वतयारी

- AWS account + an IAM user/role with admin-like rights for setup (EKS, EC2, ECR, IAM, CloudFormation).
  / Setup साठी AWS account आणि पुरेसे permissions असलेला IAM user.
- GitHub account.
- Local machine: `git`, `docker`, `aws` CLI, `kubectl`, `eksctl`.
- **Cost warning / खर्चाचा इशारा:** EKS control plane (~$0.10/hr) + 2 × t3.medium + ELB + EBS चालू असताना पैसे लागतात.
  काम झाल्यावर **Step 13 (Cleanup)** नक्की करा.

---

## 3. Step 1 - Test locally with Docker Compose / आधी local ला test करा

```bash
docker compose up --build
# open http://localhost:3000
```

**English:** Compose starts MySQL first, waits until healthy, then starts the Node app. If it works here, it will work in Kubernetes.
**मराठी:** Compose आधी MySQL चालू करतो, तो ready झाल्यावर Node app चालू करतो. इथे चालले तर Kubernetes मध्येही चालेल. बंद करायला: `docker compose down -v`.

---

## 4. Step 2 - Push code to Git / कोड Git वर टाका

```bash
cd two-tier-eks
git init
git add .
git commit -m "Initial 2-tier EKS project"
git branch -M main
git remote add origin https://github.com/<your-user>/two-tier-eks.git
git push -u origin main
```

**English:** GitHub is the single source of truth. Jenkins pulls code from here.
**मराठी:** GitHub हे "सत्याचे एकमेव ठिकाण" आहे. Jenkins इथूनच code घेतो. `02-secret.example.yaml` मध्ये खरे password नाहीत, म्हणून तो commit करणे सुरक्षित आहे.

---

## 5. Step 3 - Configure AWS CLI / AWS CLI सेट करा

```bash
aws configure          # Access key, Secret key, region = ap-south-1
aws sts get-caller-identity    # note your 12-digit Account ID
```

**मराठी:** `get-caller-identity` मधला 12 अंकी `Account` नंबर लिहून ठेवा - Jenkinsfile मध्ये लागेल.

---

## 6. Step 4 - Create the EKS cluster / EKS cluster बनवा

```bash
eksctl create cluster -f eksctl/cluster.yaml     # takes ~15-20 minutes
kubectl get nodes                                # 2 nodes Ready
```

**English:** `cluster.yaml` creates a VPC, the EKS control plane, a managed node group (2 × t3.medium), and addons:
`aws-ebs-csi-driver` (disks for MySQL) and `metrics-server` (needed by HPA).
**मराठी:** हा एक command VPC, EKS control plane, 2 worker nodes आणि गरजेचे addons बनवतो.
`aws-ebs-csi-driver` शिवाय MySQL ला disk मिळणार नाही आणि `metrics-server` शिवाय autoscaling चालणार नाही.

---

## 7. Step 5 - Create ECR repositories / ECR repos बनवा

```bash
./scripts/create-ecr.sh
```

**English:** Creates `two-tier-app` and `two-tier-db` private repositories with scan-on-push.
**मराठी:** दोन्ही tiers च्या images साठी दोन स्वतंत्र repositories बनतात.

---

## 8. Step 6 - Create the DB secret (once) / DB secret बनवा (एकदाच)

```bash
./scripts/create-secret.sh
# or choose your own passwords:
# MYSQL_ROOT_PASSWORD='...' MYSQL_PASSWORD='...' ./scripts/create-secret.sh
```

**English:** Passwords live only inside the cluster, never in Git. Jenkins checks the secret exists before deploying.
**मराठी:** Password फक्त cluster च्या आत राहतात, Git मध्ये कधीच नाही. Secret नसेल तर Jenkins deploy थांबवतो.
⚠ MySQL चा data folder एकदा बनला की password बदलले तरी जुना password चालतो - म्हणून secret पहिल्या deploy आधीच बनवा.

---

## 9. Step 7 - Set up the Jenkins server / Jenkins server सेट करा

1. Launch an **Ubuntu 22.04 EC2**, `t3.medium`, 20 GB disk, in `ap-south-1`.
   Security group: port **22** (your IP only) and **8080** (your IP only).
   / Security group मध्ये 22 आणि 8080 फक्त तुमच्या IP साठी उघडा.
2. Attach an **IAM role (instance profile)** with these permissions:
   - ECR push/pull (`AmazonEC2ContainerRegistryPowerUser`)
   - `eks:DescribeCluster`
   
   **मराठी:** Instance profile वापरल्यास Jenkins मध्ये AWS keys साठवायची गरज नाही - हे जास्त सुरक्षित आहे.
3. SSH in and run:
   ```bash
   git clone https://github.com/<your-user>/two-tier-eks.git && cd two-tier-eks
   ./scripts/install-jenkins-ubuntu.sh
   ```
   It prints the initial admin password. / Script शेवटी initial admin password दाखवते.
4. Open `http://<EC2-IP>:8080` → paste password → **Install suggested plugins** → create admin user.
5. **Give Jenkins permission to use the EKS cluster / Jenkins ला cluster access द्या.**
   From your laptop (where you created the cluster), replace the role ARN with your Jenkins EC2 role:
   ```bash
   eksctl create iamidentitymapping --cluster two-tier-eks --region ap-south-1 \
     --arn arn:aws:iam::<ACCOUNT_ID>:role/<JenkinsEC2Role> \
     --username jenkins --group system:masters
   ```
   **English:** EKS only lets IAM identities in its access list run `kubectl`. `system:masters` is simple for a demo; use a narrower role in production.
   **मराठी:** EKS फक्त ओळखीच्या IAM identity ला kubectl वापरू देते. Demo साठी `system:masters` ठीक आहे; production मध्ये कमी permission द्या.

---

## 10. Step 8 - Create the Jenkins pipeline job / Pipeline job बनवा

1. In `Jenkinsfile`, change `AWS_ACCOUNT_ID = '123456789012'` to your Account ID, commit and push.
   / Jenkinsfile मध्ये तुमचा Account ID टाका आणि push करा.
2. Jenkins → **New Item** → name `two-tier-eks` → **Multibranch Pipeline** (or plain *Pipeline* → "Pipeline script from SCM").
3. Branch Sources → **GitHub/Git** → repo URL (add credentials if the repo is private).
4. Script Path: `Jenkinsfile` → Save → **Scan Now**.

**English:** The Jenkinsfile stages:

| Stage | What it does (English) | काय करतो (मराठी) |
|---|---|---|
| Checkout | Pull code, compute image tags | Code घेतो, image tags ठरवतो |
| Unit Test | Run `npm test` in a temp Node container | Node container मध्ये tests चालवतो |
| Build Docker Images | Build app + db images | दोन्ही images बनवतो |
| Push to ECR | Login to ECR and push | ECR मध्ये push करतो |
| Deploy to EKS | Replace image placeholders, `kubectl apply`, wait for rollout | Image tag बदलून cluster वर लागू करतो |
| Smoke Test | Poll the ELB URL `/health/ready` | Public URL वर app चालतो का तपासतो |
| post: failure | `rollout undo` | Fail झाल्यास मागच्या version वर परत |

**Tagging / टॅगिंग:** App image tag = `<build#>-<git sha>`; DB image tag = hash of the `db/` folder, so MySQL restarts **only when db/ changes**.
MySQL फक्त `db/` बदलला तरच restart होतो, त्यामुळे रोजच्या app deploys मध्ये database ला त्रास नाही.

---

## 11. Step 9 - Auto-trigger on git push (webhook) / Auto trigger

1. Jenkins: install **GitHub** plugin (usually already present); in job → *Build Triggers* → **GitHub hook trigger for GITScm polling** (for Multibranch, the GitHub plugin handles it).
2. GitHub repo → **Settings → Webhooks → Add webhook**
   - Payload URL: `http://<JENKINS-IP>:8080/github-webhook/`
   - Content type: `application/json` → Push events.

**मराठी:** आता `git push` केले की Jenkins आपोआप build सुरू करतो. (Jenkins चा 8080 port GitHub च्या IP ranges साठी उघडा, किंवा polling वापरा: `H/5 * * * *`.)

---

## 12. Step 10 - Run, verify, and understand / चालवा आणि तपासा

Click **Build Now**. After success:

```bash
aws eks update-kubeconfig --name two-tier-eks --region ap-south-1
kubectl -n two-tier get pods,svc,pvc,hpa
kubectl -n two-tier get svc web-app        # EXTERNAL-IP column = public URL
```

Open `http://<EXTERNAL-IP>` in a browser. Add tasks. Refresh a few times - the footer shows **which pod** served you (load balancing).
/ Browser मध्ये URL उघडा. Task add करा. Refresh केल्यावर वेगवेगळे pod name दिसेल - हेच load balancing.

**Useful tests / उपयुक्त टेस्ट्स**

```bash
# 1) Data persistence: delete the DB pod, data should survive
kubectl -n two-tier delete pod mysql-0
kubectl -n two-tier get pods -w        # mysql-0 comes back, tasks are still there

# 2) Self-healing: delete an app pod
kubectl -n two-tier delete pod $(kubectl -n two-tier get pod -l app=web-app -o name | head -1)

# 3) Scale manually
kubectl -n two-tier scale deployment web-app --replicas=3

# 4) Rollback
kubectl -n two-tier rollout history deployment/web-app
kubectl -n two-tier rollout undo deployment/web-app

# 5) Logs & DB shell
kubectl -n two-tier logs deploy/web-app
kubectl -n two-tier exec -it mysql-0 -- mysql -uappuser -p appdb -e "SELECT * FROM tasks;"
```

**मराठी:** MySQL pod delete केला तरी data जात नाही कारण data EBS volume (PVC) वर आहे, pod च्या आत नाही.
App pod delete केला तर Deployment आपोआप नवीन बनवतो (self-healing).

---

## 13. Cleanup (important!) / साफसफाई - खर्च टाळण्यासाठी

```bash
kubectl delete ns two-tier             # deletes ELB (Service); PVC/EBS: StorageClass reclaimPolicy=Retain,
                                       # so delete leftover EBS volumes manually in EC2 console
eksctl delete cluster -f eksctl/cluster.yaml
aws ecr delete-repository --repository-name two-tier-app --force --region ap-south-1
aws ecr delete-repository --repository-name two-tier-db  --force --region ap-south-1
# Terminate the Jenkins EC2 instance and delete leftover EBS volumes
```

**मराठी:** `kubectl delete ns` आधी करा (म्हणजे ELB जातो), नंतर cluster delete करा. `Retain` मुळे EBS volume राहतो - EC2 → Volumes मध्ये manually delete करा, नाहीतर बिल येत राहील.

---

## 14. Troubleshooting / अडचणी आणि उपाय

| Problem | Likely cause / Fix |
|---|---|
| `mysql-0` Pending | EBS CSI addon missing, or StorageClass not applied → `kubectl describe pvc -n two-tier` |
| App pod `0/1 Ready` | DB not ready or wrong secret → `kubectl logs deploy/web-app -n two-tier` |
| `ImagePullBackOff` | ECR image/tag missing, or node role lacks ECR read (default eksctl node role has it) |
| Jenkins: `Unauthorized` on kubectl | Step 9.5 identity mapping missing |
| Jenkins: `permission denied ... docker.sock` | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `EXTERNAL-IP <pending>` | Wait 2-3 min for ELB; check subnets are public/tagged (eksctl does this) |
| HPA shows `<unknown>` | metrics-server not running → `kubectl get deploy metrics-server -n kube-system` |

---

## 15. Production hardening ideas / पुढचे सुधार

- Use **Amazon RDS MySQL** (Multi-AZ) instead of a self-managed StatefulSet / DB साठी RDS वापरा.
- **AWS Load Balancer Controller + ALB Ingress + ACM (HTTPS)** + Route 53 domain.
- Move secrets to **AWS Secrets Manager + External Secrets Operator**.
- Enable **NetworkPolicy** (`k8s/optional/networkpolicy.yaml`), Pod Security, image scanning (Trivy) in Jenkins.
- Use **Helm/Kustomize** per-environment (dev/stage/prod), and a narrower IAM role than `system:masters`.
- Run Jenkins agents as Kubernetes pods instead of one EC2.
