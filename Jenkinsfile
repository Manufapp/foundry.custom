// Deploys FE/BE image versions to an on-prem customer server over SSH.
// Equivalent to logging in and running:
//   cd <dir> && ./manufapp.sh stop && IMAGE_TAG_FE=<fe> IMAGE_TAG_BE=<be> ./manufapp.sh start
//
// Jenkins job: foundry-custom-deploy (Pipeline script from SCM, branch dev).
// Per-customer SSH private keys are Jenkins "SSH Username with private key" credentials
// whose IDs are listed in CUSTOMERS below.

// TODO: fill in real values per customer before the first run.
def CUSTOMERS = [
    atc: [
        host: 'TODO-atc-host', port: '22', user: 'TODO', dir: '~/foundry.custom',
        credId: 'onprem-atc-ssh'
    ],
    ambrane: [
        host: 'TODO-ambrane-host', port: '22', user: 'TODO', dir: '~/foundry.custom',
        credId: 'onprem-ambrane-ssh'
    ],
    salasar: [
        host: '139.5.198.14', port: '22', user: 'productionserver', dir: '~/foundry.custom',
        credId: 'onprem-salasar-ssh'
    ],
]

pipeline {
    agent any

    parameters {
        choice(name: 'CUSTOMER', choices: ['salasar'], description: 'On-prem customer to deploy to (atc/ambrane to be re-enabled once ready)')
        string(name: 'FE_VERSION', defaultValue: '', trim: true, description: 'Frontend image tag, e.g. 1.39.0')
        string(name: 'BE_VERSION', defaultValue: '', trim: true, description: 'Backend image tag, e.g. v1.39.0')
    }

    environment {
        AWS_PROFILE = 'manufapp'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
    }

    stages {
        stage('Validate') {
            steps {
                script {
                    // Versions are interpolated into a remote shell command, so only
                    // allow plain tag characters.
                    def tag = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
                    if (!(params.FE_VERSION ==~ tag)) { error "FE_VERSION '${params.FE_VERSION}' is empty or invalid" }
                    if (!(params.BE_VERSION ==~ tag)) { error "BE_VERSION '${params.BE_VERSION}' is empty or invalid" }
                    def cfg = CUSTOMERS[params.CUSTOMER]
                    if (cfg == null || cfg.host.startsWith('TODO')) {
                        error "No host configured for customer '${params.CUSTOMER}' in Jenkinsfile"
                    }
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${params.CUSTOMER} FE=${params.FE_VERSION} BE=${params.BE_VERSION}"
                }
            }
        }

        stage('Deploy') {
            steps {
                script {
                    def cfg = CUSTOMERS[params.CUSTOMER]
                    sshagent(credentials: [cfg.credId]) {
                        // Single command argument with stdin closed (-n): feeding the script over
                        // stdin let `docker compose` in `stop` swallow the rest of it, so `start`
                        // never ran. manufapp.sh start pulls the new images (ECR login + compose pull).
                        sh """
                            ssh -n -p ${cfg.port} -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
                                ${cfg.user}@${cfg.host} \
                                'set -e; cd ${cfg.dir} && ./manufapp.sh stop && IMAGE_TAG_FE=${params.FE_VERSION} IMAGE_TAG_BE=${params.BE_VERSION} ./manufapp.sh start'
                        """
                    }
                }
            }
        }

        stage('Verify') {
            steps {
                script {
                    def cfg = CUSTOMERS[params.CUSTOMER]
                    sshagent(credentials: [cfg.credId]) {
                        sh """
                            ssh -n -p ${cfg.port} -o StrictHostKeyChecking=accept-new \
                                ${cfg.user}@${cfg.host} 'cd ${cfg.dir} && ./manufapp.sh status'
                        """
                    }
                }
            }
        }
    }

    post {
        success {
            echo "✅ ${params.CUSTOMER} deployed FE=${params.FE_VERSION} BE=${params.BE_VERSION}"
            sh """
                cat > /tmp/ses-msg.json << EOF
{"Subject":{"Data":"[Jenkins] foundry.custom ${params.CUSTOMER} deployment succeeded","Charset":"UTF-8"},"Body":{"Text":{"Data":"Build #${env.BUILD_NUMBER}: ${params.CUSTOMER} FE=${params.FE_VERSION} BE=${params.BE_VERSION} deployed.\\n\\n${env.BUILD_URL}console","Charset":"UTF-8"}}}
EOF
                aws ses send-email --region ap-south-1 \
                  --from contact@manufapp.com \
                  --to abhinavkaul95@manufapp.com \
                  --message file:///tmp/ses-msg.json
            """
        }
        failure {
            echo "❌ ${params.CUSTOMER} deployment FAILED"
            sh """
                cat > /tmp/ses-msg.json << EOF
{"Subject":{"Data":"[Jenkins] foundry.custom ${params.CUSTOMER} deployment FAILED","Charset":"UTF-8"},"Body":{"Text":{"Data":"Build #${env.BUILD_NUMBER}: ${params.CUSTOMER} FE=${params.FE_VERSION} BE=${params.BE_VERSION} failed.\\n\\nConsole: ${env.BUILD_URL}console","Charset":"UTF-8"}}}
EOF
                aws ses send-email --region ap-south-1 \
                  --from contact@manufapp.com \
                  --to abhinavkaul95@manufapp.com \
                  --message file:///tmp/ses-msg.json
            """
        }
    }
}
