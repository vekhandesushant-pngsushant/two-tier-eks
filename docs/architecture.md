# Architecture / आर्किटेक्चर

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
                  |        AWS Cloud - Region ap-south-1
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

| Component | Purpose (English) | उद्देश (मराठी) |
|---|---|---|
| Git | Source code + version history | सोर्स कोड आणि बदलांचा इतिहास |
| Jenkins | CI/CD automation | कोड बदलला की आपोआप test, build, deploy |
| Docker | Package app into images | App ला image मध्ये पॅक करतो |
| ECR | Private image registry | Docker images साठवायची जागा |
| EKS | Managed Kubernetes | AWS चा managed Kubernetes cluster |
| Deployment | Stateless app pods | App चे pods (restart झाले तरी चालतात) |
| StatefulSet + PVC | Stateful DB with persistent disk | DB साठी - pod गेला तरी data टिकतो |
| ELB | Public entry point | बाहेरून येणारा traffic आत पाठवतो |
