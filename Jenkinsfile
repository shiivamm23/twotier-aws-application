pipeline {
    agent any

    environment {
        AWS_REGION = 'ap-south-1'
        ECR_REPO   = 'twotier-app'
        CLUSTER    = 'twotier-cluster'
        SERVICE    = 'twotier-service'
    }

    stages {
        stage('Checkout') {
            steps { checkout scm }
        }

        stage('Test (syntax check)') {
            steps {
                sh '''
                  docker run --rm -v "$WORKSPACE/app":/app -w /app node:20-alpine \
                    sh -c "npm install --omit=dev && node --check server.js"
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh 'docker build -t $ECR_REPO:$BUILD_NUMBER ./app'
            }
        }

        stage('Push to ECR') {
            steps {
                sh '''
                  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
                  REGISTRY=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
                  aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY
                  docker tag $ECR_REPO:$BUILD_NUMBER $REGISTRY/$ECR_REPO:$BUILD_NUMBER
                  docker tag $ECR_REPO:$BUILD_NUMBER $REGISTRY/$ECR_REPO:latest
                  docker push $REGISTRY/$ECR_REPO:$BUILD_NUMBER
                  docker push $REGISTRY/$ECR_REPO:latest
                '''
            }
        }

        stage('Deploy to ECS') {
            steps {
                sh '''
                  aws ecs update-service --cluster $CLUSTER --service $SERVICE --force-new-deployment --region $AWS_REGION
                  aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE --region $AWS_REGION
                '''
            }
        }
    }

    post {
        success { echo 'Deployment successful' }
        failure { echo 'Pipeline failed - check the stage logs' }
        always  { sh 'docker image prune -f' }
    }
}
