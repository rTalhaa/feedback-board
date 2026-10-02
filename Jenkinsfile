// Jenkins CI/CD for the EC2 track: test -> scan -> package -> CodeDeploy in-place release.
pipeline {
  agent any
  triggers { pollSCM('H/5 * * * *') }
  options { timestamps(); disableConcurrentBuilds() }
  environment {
    AWS_DEFAULT_REGION = 'ap-south-1'
    APP   = 'feedback-ec2-prod'
    GROUP = 'feedback-ec2-prod-inplace'
  }
  stages {
    stage('Test') {
      steps {
        sh '''
          python3.12 -m venv .venv && . .venv/bin/activate
          pip install -q -r app/requirements.txt pytest pip-audit
          python lambda/handler.py
          (cd app && python -m pytest -q --junitxml=../reports/junit.xml)
        '''
      }
      post { always { junit 'reports/junit.xml' } }
    }
    stage('Vulnerability scan') {
      steps { sh '. .venv/bin/activate && pip-audit -r app/requirements.txt' }
    }
    stage('Package') {
      steps {
        script {
          env.BUCKET = "feedback-board-artifacts-" + sh(returnStdout: true, script: 'aws sts get-caller-identity --query Account --output text').trim()
        }
        sh '''
          cp app/app.py app/requirements.txt ec2-deploy/
          aws deploy push --application-name "$APP" --source ec2-deploy \
            --s3-location "s3://$BUCKET/ec2/feedback-${GIT_COMMIT}.zip" --description "build ${BUILD_NUMBER}"
        '''
      }
    }
    stage('Deploy (CodeDeploy in-place)') {
      steps {
        sh '''
          ID=$(aws deploy create-deployment --application-name "$APP" --deployment-group-name "$GROUP" \
            --s3-location bucket="$BUCKET",key="ec2/feedback-${GIT_COMMIT}.zip",bundleType=zip \
            --query deploymentId --output text)
          echo "CodeDeploy deployment: $ID"
          aws deploy wait deployment-successful --deployment-id "$ID"
        '''
      }
    }
  }
}
