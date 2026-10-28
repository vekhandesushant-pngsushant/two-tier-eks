pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '15'))
    timeout(time: 30, unit: 'MINUTES')
  }

  environment {
    AWS_REGION     = 'ap-south-1'
    AWS_ACCOUNT_ID = '946877383530'          
    CLUSTER_NAME   = 'two-tier-eks'
    NAMESPACE      = 'two-tier'
    ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    APP_REPO       = 'two-tier-app'
    DB_REPO        = 'two-tier-db'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm        
        sh 'git log -1 --oneline'
        script {
          def sha = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD').trim()
          // App tag: pratyek build la navin
          env.IMAGE_TAG = "${env.BUILD_NUMBER}-${sha}"
          // DB tag: fakt db/ folder badalla tarach badalto => MySQL unnecessarily restart hot nahi
          env.DB_TAG = sh(returnStdout: true, script: 'git rev-parse --short=7 HEAD:db').trim()
          echo "APP tag=${env.IMAGE_TAG}  DB tag=${env.DB_TAG}"
        }
      }
    }

    stage('Unit Test') {
      steps {
        
        sh '''
          docker run --rm --user $(id -u):$(id -g) \
            -e npm_config_cache=/tmp/.npm -e HOME=/tmp \
            -v "$WORKSPACE/app":/usr/src/app -w /usr/src/app \
            node:20-alpine sh -c "npm install && npm test"
        '''
      }
    }

    stage('Build Docker Images') {
      steps {
        sh '''
          docker build -t ${ECR_REGISTRY}/${APP_REPO}:${IMAGE_TAG} -t ${ECR_REGISTRY}/${APP_REPO}:latest ./app
          docker build -t ${ECR_REGISTRY}/${DB_REPO}:${DB_TAG}  -t ${ECR_REGISTRY}/${DB_REPO}:latest  ./db
        '''
      }
    }

    stage('Push to ECR') {
      steps {
        
        
        sh '''
          aws ecr get-login-password --region ${AWS_REGION} \
            | docker login --username AWS --password-stdin ${ECR_REGISTRY}
          docker push ${ECR_REGISTRY}/${APP_REPO}:${IMAGE_TAG}
          docker push ${ECR_REGISTRY}/${APP_REPO}:latest
          docker push ${ECR_REGISTRY}/${DB_REPO}:${DB_TAG}
          docker push ${ECR_REGISTRY}/${DB_REPO}:latest
        '''
      }
    }

    stage('Deploy to EKS') {
      when { expression { env.BRANCH_NAME == null || env.BRANCH_NAME == 'main' } }   // fakt main deploy hoil
      steps {
        sh '''
          aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

          # Placeholders replace kara
          rm -rf rendered && mkdir rendered && cp k8s/*.yaml rendered/
          rm -f rendered/02-secret.example.yaml            # real secret Git madhe nasto
          sed -i "s|ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com|${ECR_REGISTRY}|g" rendered/*.yaml
          sed -i "s|APP_IMAGE_TAG|${IMAGE_TAG}|g"  rendered/06-app-deployment.yaml
          sed -i "s|DB_IMAGE_TAG|${DB_TAG}|g"     rendered/04-mysql-statefulset.yaml

          kubectl apply -f rendered/00-namespace.yaml
          kubectl -n ${NAMESPACE} get secret mysql-secret >/dev/null \
            || { echo "mysql-secret missing! Run scripts/create-secret.sh once."; exit 1; }
          kubectl apply -f rendered/

          kubectl -n ${NAMESPACE} rollout status statefulset/mysql  --timeout=300s
          kubectl -n ${NAMESPACE} rollout status deployment/web-app --timeout=300s
        '''
      }
    }

    stage('Smoke Test') {
      when { expression { env.BRANCH_NAME == null || env.BRANCH_NAME == 'main' } }
      steps {
        sh '''
          for i in $(seq 1 30); do
            LB=$(kubectl -n ${NAMESPACE} get svc web-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
            [ -n "$LB" ] && break; echo "Waiting for LoadBalancer..."; sleep 10
          done
          echo "URL: http://$LB"
          for i in $(seq 1 30); do
            curl -sf "http://$LB/health/ready" && exit 0
            echo "not ready yet ($i/30)"; sleep 10
          done
          echo "Smoke test FAILED"; exit 1
        '''
      }
    }
  }

  post {
    failure {
      
      sh '''
        kubectl -n ${NAMESPACE} rollout undo deployment/web-app || true
      '''
    }
    always {
      sh 'docker image prune -f || true'
    }
  }
}
