# Two-Tier App on AWS: Complete Deployment Guide

## 0. What you are building

```
 Developer --git push--> GitHub --> Jenkins (EC2) --docker build/push--> ECR (image registry)
                                          |                                  |
                                          +--- aws ecs update-service ---> ECS Fargate (Tier 1: Node.js app, 2 copies, private subnets)
                                                                               |  port 5432
 Internet --> Application Load Balancer (public subnets)                       v
                                                                  RDS PostgreSQL (Tier 2: database, private subnet)
```

- **Tier 1 (application):** Node.js + Express, serves a web page and a REST API.
- **Tier 2 (database):** PostgreSQL. Locally it is a container; on AWS it is RDS.
- **Terraform** creates all AWS infrastructure as code.
- **Docker** packages the app so it runs identically everywhere.
- **Jenkins (on EC2)** automates: build image, push to ECR, redeploy to ECS.
- **ECS** is the main deployment. **EKS** is an alternative (Section 9). **EC2** hosts Jenkins.

**Cost warning:** NAT Gateway, RDS, ALB, Fargate, EC2 and EKS all cost money (roughly a few USD/day for everything; EKS control plane is about $0.10/hour). Run the cleanup in Section 10 when finished.

---

## 1. Install the tools (why: you need each one on your laptop)

| Tool | Why you need it | Check |
|---|---|---|
| VS Code | Editor | |
| Git | Version control; Jenkins pulls your code from Git | `git --version` |
| Node.js 20 | Optional, to run the app without Docker | `node -v` |
| Docker Desktop | Build and run containers | `docker --version` |
| AWS CLI v2 | Talk to AWS from the terminal | `aws --version` |
| Terraform >= 1.5 | Create AWS infrastructure from code | `terraform -version` |
| kubectl | Only for the EKS path | `kubectl version --client` |

### Give the AWS CLI credentials
1. AWS Console > IAM > Users > create a user (for learning, attach `AdministratorAccess`; in a company use least privilege) > Security credentials > Create access key (CLI).
2. In a terminal run:
```
aws configure
```
It asks for: Access Key ID, Secret Access Key, default region (`ap-south-1` = Mumbai), output format (`json`).
It saves them in `~/.aws/credentials`. Terraform automatically uses the same credentials.

3. Verify:
```
aws sts get-caller-identity
```
This asks AWS "who am I?" and prints your account ID. If it works, authentication is correct.

**Why first:** every later step talks to AWS; failing here saves you confusion later.

---

## 2. Open the project in VS Code

Unzip the project, then `File > Open Folder`. Structure:

```
twotier-aws/
  app/                  Tier 1 source code + Dockerfile
    server.js           Express API + DB code
    public/index.html   Web page
    package.json        Dependencies
    Dockerfile          Recipe to build the image
    .dockerignore       Files NOT to copy into the image
  docker-compose.yml    Run app + database locally together
  Jenkinsfile           CI/CD pipeline definition
  terraform/
    ecs/                VPC, ECR, RDS, ECS, ALB (main infra)
    jenkins-ec2/        EC2 server running Jenkins
    eks/                Optional Kubernetes cluster
  k8s/app.yaml          Kubernetes manifests (EKS path)
  .gitignore            Files Git must never commit (state, passwords)
```

---

## 3. Understand the application files

### app/package.json
Lists the app name and dependencies: `express` (web framework) and `pg` (PostgreSQL driver). `npm install` reads this file.

### app/server.js (what each block does)
- `new Pool({...})` creates a pool of reusable DB connections. Host, user, and password come from **environment variables**, so the same image works locally, on ECS and on EKS without code changes.
- `ssl: DB_SSL === 'true'`: RDS Postgres 15+ requires encrypted connections, so ECS sets `DB_SSL=true`.
- `initDb()` creates the `tasks` table if missing and **retries** for about 45 seconds, because during startup the DB may not be ready yet.
- `GET /health` returns `OK` without touching the DB. The load balancer calls this to decide if a container is healthy. It deliberately avoids the DB so a DB hiccup doesn't make the LB kill all containers.
- `GET/POST/DELETE /api/tasks` read, add, delete rows. `$1` placeholders prevent SQL injection.

### app/Dockerfile (line by line)
| Line | Meaning |
|---|---|
| `FROM node:20-alpine` | Start from an official small Linux image that already has Node 20 |
| `WORKDIR /app` | All following commands run in `/app` inside the image |
| `COPY package*.json ./` | Copy only dependency files first. Docker caches each step; if your code changes but dependencies don't, the slow `npm install` is skipped next build |
| `RUN npm install --omit=dev` | Install production dependencies during build |
| `COPY . .` | Copy the rest of the code (`.dockerignore` excludes `node_modules` etc.) |
| `USER node` | Run as a non-root user; limits damage if the app is hacked |
| `EXPOSE 3000` | Documents the port (informational) |
| `CMD ["node","server.js"]` | The command executed when a container starts |

### docker-compose.yml
Defines two containers for local testing: `db` (official postgres image, a named volume `dbdata` keeps data) and `app` (built from `./app`, maps port 3000 to your laptop). `DB_HOST: db` works because Compose creates a network where each service is reachable by its name. `depends_on` starts `db` first.

---

## 4. Test locally first (why: finding bugs on your laptop is free and fast; finding them on AWS costs time and money)

```
docker compose up --build
```
- `docker compose up` starts every service in the file.
- `--build` rebuilds the image from your Dockerfile.

Open http://localhost:3000, add a few tasks. Stop with `Ctrl+C`, remove containers with `docker compose down`.

---

## 5. Put the code in Git (why: Jenkins pulls the code from a Git repo)

Create an empty repo on GitHub, then in the project folder:
```
git init                          # turn this folder into a Git repository
git add .                         # stage all files (.gitignore keeps secrets out)
git commit -m "Initial commit"    # save a snapshot
git branch -M main                # name the branch main
git remote add origin https://github.com/<you>/<repo>.git   # link to GitHub
git push -u origin main           # upload
```

---

## 6. Terraform basics (read once)

Terraform reads `.tf` files describing the infrastructure you want ("desired state") and makes AWS match it.

| Command | What it does |
|---|---|
| `terraform init` | Downloads the AWS provider plugin into `.terraform/`. Run once per folder |
| `terraform validate` | Checks syntax |
| `terraform plan` | Dry run: shows what would be created/changed/destroyed. Nothing is touched |
| `terraform apply` | Executes the plan after you type `yes` |
| `terraform output` | Prints values declared in `outputs.tf` |
| `terraform destroy` | Deletes everything it created |

Terraform records what it created in `terraform.tfstate`. **Never commit it and never delete it** (it may contain secrets, and losing it means Terraform forgets your resources).

### Terraform files in `terraform/ecs/`
- **providers.tf**: pins Terraform and AWS provider versions; sets the region.
- **variables.tf**: inputs (region, names, DB password). `sensitive = true` hides the password in output.
- **network.tf**: the networking foundation.
  - *VPC* = your private network (10.0.0.0/16).
  - *Public subnets* (2, in 2 Availability Zones): contain the load balancer and NAT gateway; route to the *Internet Gateway*.
  - *Private subnets* (2): contain app containers and database; no inbound internet access. They reach the internet outward (to pull images) via the *NAT Gateway*.
  - *Security groups* = firewalls chained together: Internet to ALB on 80; only ALB to app on 3000; only app to DB on 5432. The DB can never be reached directly from the internet.
- **ecr.tf**: private Docker registry (Elastic Container Registry) where images are stored.
- **rds.tf**: managed PostgreSQL 16 in private subnets (`publicly_accessible = false`).
- **ecs.tf**:
  - *Secrets Manager* secret stores the DB password; ECS injects it into the container at start (so it never appears in the task definition in plain text).
  - *IAM execution role*: permission for ECS to pull from ECR, write logs, read that secret.
  - *CloudWatch log group*: where container logs go.
  - *ECS cluster*: logical group. *Task definition*: blueprint (image, CPU/memory, env vars, port, logs). *Service*: keeps 2 copies running, replaces failed ones, registers them with the load balancer.
  - *Fargate* = AWS runs the containers; you manage no servers.
  - *ALB + target group + listener*: public entry point on port 80, forwards to containers, health-checks `/health`.
- **outputs.tf**: prints the app URL, ECR URL, DB endpoint.

---

## 7. Deploy the infrastructure to ECS (ordered, with reasons)

### Step 7.1: Create the registry first
```
cd terraform/ecs
cp terraform.tfvars.example terraform.tfvars    # then edit and set your DB password
terraform init
terraform apply -target=aws_ecr_repository.app
```
**Why:** the ECS service needs an image to run, and the image needs a registry to live in. This is a chicken-and-egg problem, so we create only the ECR repo first (`-target` limits Terraform to one resource). Type `yes`.

### Step 7.2: Build and push the first image manually
```
ECR_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${ECR_URL%%/*}
docker build --platform linux/amd64 -t $ECR_URL:latest ../../app
docker push $ECR_URL:latest
```
- Line 1 saves the repo address in a shell variable.
- Line 2: `aws ecr get-login-password` prints a temporary token (valid 12h); `docker login ... --password-stdin` feeds it to Docker. `${ECR_URL%%/*}` strips everything after the first `/`, leaving the registry host.
- Line 3: builds the image; `-t` names/tags it. `--platform linux/amd64` matters if you use an Apple Silicon Mac (Fargate here runs x86).
- Line 4: uploads to ECR.

(On Windows PowerShell, set the variable with `$ECR_URL = terraform output -raw ecr_repository_url` and use `$($ECR_URL.Split('/')[0])` for the host.)

**Why now:** the image must exist before the ECS service starts, otherwise tasks fail with "image not found".

### Step 7.3: Create everything else
```
terraform plan
terraform apply
```
Takes about 10 to 15 minutes (RDS and NAT are slow). When done, Terraform prints `app_url`. Open it in a browser. The first minute may show 503 while containers pass health checks.

### Debugging tips
- ECS Console > Clusters > twotier-cluster > Services > Tasks / Events.
- CloudWatch > Log groups > `/ecs/twotier` for app logs.
- Target group unhealthy? Check that `/health` returns 200 and security groups are as defined.

---

## 8. Jenkins on EC2: automate future deployments

### Step 8.1: Create an EC2 key pair
EC2 Console > Key Pairs > Create (same region) > download the `.pem`. **Why:** lets you SSH in to read Jenkins' first password.

### Step 8.2: Launch the Jenkins server with Terraform
```
cd ../jenkins-ec2
terraform init
terraform apply -var="key_name=<your-key-name>" -var="my_ip_cidr=<your-public-ip>/32"
```
(Find your IP at https://checkip.amazonaws.com.) **Why restrict to your IP:** Jenkins can deploy to your AWS account; it must not be open to the world.

What `main.tf` creates: a security group (SSH 22 and Jenkins 8080 from your IP only), an **IAM role** with just the ECR push + ECS update permissions (so no access keys are stored on the server), an instance profile (attaches the role to the EC2), and a `t3.medium` Amazon Linux 2023 instance.
`user_data.sh` runs automatically on first boot: installs Docker, Git, Java 17, then Jenkins from its official repo, adds the `jenkins` user to the `docker` group (so pipelines can run `docker`), and starts services. Wait about 3 to 5 minutes.

### Step 8.3: Unlock Jenkins
```
ssh -i your-key.pem ec2-user@<jenkins-ip>
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```
Open `http://<jenkins-ip>:8080`, paste the password, choose **Install suggested plugins**, create an admin user.
Then: Manage Jenkins > Plugins > install **Pipeline** and **Git** if missing (usually included).

### Step 8.4: Create the pipeline job
1. New Item > name `twotier` > **Pipeline** > OK.
2. Pipeline section > Definition: **Pipeline script from SCM** > SCM: Git > your repo URL > branch `*/main` > Script Path: `Jenkinsfile`. (Private repo? Add a GitHub token under Credentials.)
3. Save > **Build Now**.

### The Jenkinsfile explained
- `pipeline { agent any ... }`: declarative pipeline; run on any available Jenkins node.
- `environment { ... }`: variables for all stages. They must match your Terraform names (`twotier-app`, `twotier-cluster`, `twotier-service`) and region.
- **Checkout**: `checkout scm` pulls the repo configured in the job.
- **Test**: runs a throwaway `node:20-alpine` container (`docker run --rm`), mounts the workspace (`-v`), sets the folder (`-w`), installs deps and runs `node --check server.js` (syntax check). It's a minimal example; replace with real unit tests as the app grows. If it fails, the pipeline stops, so broken code never ships.
- **Build Docker Image**: `docker build -t name:BUILD_NUMBER ./app`. `$BUILD_NUMBER` is Jenkins' counter, giving each image a unique, traceable tag.
- **Push to ECR**:
  - `aws sts get-caller-identity --query Account --output text` gets the account ID from the instance role.
  - `aws ecr get-login-password | docker login ...` authenticates Docker to ECR.
  - `docker tag` adds registry-prefixed names; we push both `:BUILD_NUMBER` (permanent history for rollbacks) and `:latest` (what ECS runs).
- **Deploy to ECS**: `aws ecs update-service --force-new-deployment` tells ECS to start new tasks (which pull the new `:latest`) and gradually replace old ones (rolling update, zero downtime). `aws ecs wait services-stable` blocks until the rollout finishes, so the build shows red if the deploy fails.
- `post { ... }`: runs after stages; `docker image prune -f` deletes unused images so the disk doesn't fill.

### Try it
Edit the heading in `app/public/index.html`, then `git add . && git commit -m "change" && git push`. In Jenkins click **Build Now** (or add a GitHub webhook to `http://<jenkins-ip>:8080/github-webhook/` plus the job's "GitHub hook trigger" option; webhooks need port 8080 reachable from GitHub, so for a learning setup, manual builds or "Poll SCM" are simpler). Refresh the app URL after the pipeline succeeds.

---

## 9. Alternative: deploy the same app to EKS (Kubernetes)

**Why use EKS instead of ECS:** Kubernetes is the industry standard, portable across clouds, with a larger ecosystem. ECS is simpler and cheaper. Use only one path at a time to control cost. You still need the ECR image from Step 7.2.

### Step 9.1: Create the cluster (15 to 20 minutes)
```
cd terraform/eks
terraform init
terraform apply
```
`main.tf` uses two community modules: `vpc` (network with tags telling Kubernetes where to place load balancers) and `eks` (control plane plus a managed node group of 2 `t3.small` EC2 workers). `enable_cluster_creator_admin_permissions` makes your IAM user a cluster admin so `kubectl` works. Worker nodes automatically get permission to pull from ECR. If the Kubernetes version is rejected, set `-var="cluster_version=<a currently supported version>"`.

### Step 9.2: Connect kubectl
```
aws eks update-kubeconfig --region ap-south-1 --name twotier-eks
kubectl get nodes
```
The first command writes the cluster address and auth settings into `~/.kube/config`. The second should show 2 `Ready` nodes.

### Step 9.3: Deploy
```
cd ../..
ECR_URL=$(terraform -chdir=terraform/ecs output -raw ecr_repository_url)
sed -i.bak "s|REPLACE_ME_ECR_URL|$ECR_URL|" k8s/app.yaml
kubectl apply -f k8s/app.yaml
kubectl get pods
kubectl get svc web
```
`sed` substitutes your image address. `kubectl apply -f` creates what the file declares:
- **Secret**: holds the DB password.
- **Deployment `postgres` + Service `postgres`**: Tier 2; the Service gives it the stable DNS name `postgres`, which is what `DB_HOST` uses.
- **Deployment `web`** (2 replicas) + **Service `web`** of type `LoadBalancer`: Kubernetes asks AWS to create a public load balancer. `readinessProbe` hits `/health` so traffic only goes to ready pods.

`kubectl get svc web` shows an `EXTERNAL-IP` hostname after about 2 minutes. Open it in a browser.
Note: the demo database uses `emptyDir`, so data disappears if the DB pod restarts. In production use RDS or a PersistentVolume.

To redeploy after Jenkins pushes a new `:latest`: `kubectl rollout restart deployment/web`. (You could add that as a pipeline stage with kubectl configured on the Jenkins server.)

---

## 10. Cleanup (very important: stops billing)

```
kubectl delete -f k8s/app.yaml        # EKS only: removes the AWS load balancer first
cd terraform/eks && terraform destroy
cd ../jenkins-ec2 && terraform destroy -var="key_name=<key>" -var="my_ip_cidr=<ip>/32"
cd ../ecs && terraform destroy
```
Delete the Kubernetes service first, otherwise the load balancer it created lives outside Terraform and blocks VPC deletion. Finally, check the EC2, RDS, VPC, and Load Balancer consoles to confirm nothing remains.

---

## 11. Why this order? (summary)

1. **Credentials**: nothing works without AWS access.
2. **Local test**: cheapest place to catch app bugs.
3. **Git**: Jenkins needs a source of truth.
4. **ECR first, then image, then rest of infra**: ECS needs an image that needs a registry.
5. **Infra via Terraform**: repeatable, reviewable, destroyable.
6. **Jenkins after infra**: the pipeline needs the ECR repo, cluster and service to already exist.
7. **EKS optional**: same image, different orchestrator.

## 12. Next improvements (production)
HTTPS with ACM certificate on the ALB; Terraform remote state in S3 + DynamoDB lock; RDS Multi-AZ and backups; auto scaling for the ECS service; unique image tags in the task definition instead of `latest`; run Jenkins behind HTTPS; use a Jenkins agent instead of building on the controller.
