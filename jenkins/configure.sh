#!/bin/bash
# Configures the Jenkins server as code (run via SSM Run Command, as root):
# plugins, admin user, security, and the pipeline job for this repository. Skips the setup wizard.
set -euo pipefail
REPO=${REPO:-https://github.com/rTalhaa/feedback-board.git}
HOME_DIR=/var/lib/jenkins

# Admin password is generated on the server and never leaves it except via SSM to the operator.
[ -s $HOME_DIR/admin-password ] || python3 -c 'import secrets; print(secrets.token_urlsafe(15))' > $HOME_DIR/admin-password
chown jenkins:jenkins $HOME_DIR/admin-password && chmod 600 $HOME_DIR/admin-password

PIM=https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.15.0/jenkins-plugin-manager-2.15.0.jar
curl -sfL -o /tmp/pim.jar "$PIM"
echo "$(curl -sfL "$PIM.sha256" | cut -d' ' -f1)  /tmp/pim.jar" | sha256sum -c -
java -jar /tmp/pim.jar --war /usr/share/java/jenkins.war --plugin-download-directory $HOME_DIR/plugins \
  --plugins workflow-aggregator git pipeline-stage-view pipeline-graph-view junit timestamper
chown -R jenkins:jenkins $HOME_DIR/plugins

# /tmp on Amazon Linux is a ~1 GB RAM disk, under Jenkins' 1 GiB free-space threshold (node goes offline).
mkdir -p $HOME_DIR/tmp /etc/systemd/system/jenkins.service.d && chown jenkins:jenkins $HOME_DIR/tmp
printf '[Service]\nEnvironment="JAVA_OPTS=-Djava.awt.headless=true -Djava.io.tmpdir=%s/tmp"\n' $HOME_DIR \
  > /etc/systemd/system/jenkins.service.d/tmpdir.conf
systemctl daemon-reload

mkdir -p $HOME_DIR/init.groovy.d
cat > $HOME_DIR/init.groovy.d/setup.groovy <<EOF
import jenkins.model.*
import jenkins.install.InstallState
import hudson.security.*
import hudson.plugins.git.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition

def j = Jenkins.get()
def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount('admin', new File('$HOME_DIR/admin-password').text.trim())
j.setSecurityRealm(realm)
def auth = new FullControlOnceLoggedInAuthorizationStrategy()
auth.setAllowAnonymousRead(false)
j.setAuthorizationStrategy(auth)
j.setInstallState(InstallState.INITIAL_SETUP_COMPLETED)
j.setNumExecutors(2)   // single-server setup: builds run on the built-in node
if (j.getItem('feedback-board-ec2') == null) {
  def scm = new GitSCM(GitSCM.createRepoList('$REPO', null), [new BranchSpec('*/main')], null, null, [])
  j.createProject(WorkflowJob, 'feedback-board-ec2').setDefinition(new CpsScmFlowDefinition(scm, 'Jenkinsfile'))
}
j.save()
new File('$HOME_DIR/init.groovy.d/setup.groovy').delete()   // one-shot
EOF
chown -R jenkins:jenkins $HOME_DIR/init.groovy.d
systemctl restart jenkins

# Wait for Jenkins, then start the first build (later builds come from SCM polling).
for _ in $(seq 60); do curl -sf -o /dev/null http://localhost:8080/login && break; sleep 5; done
PW=$(cat $HOME_DIR/admin-password)
curl -sf -u "admin:$PW" -c /tmp/cj -b /tmp/cj -o /tmp/crumb http://localhost:8080/crumbIssuer/api/json
CRUMB=$(python3 -c "import json;d=json.load(open('/tmp/crumb'));print(d['crumbRequestField']+':'+d['crumb'])")
curl -sf -u "admin:$PW" -c /tmp/cj -b /tmp/cj -H "$CRUMB" -X POST http://localhost:8080/job/feedback-board-ec2/build
rm -f /tmp/cj /tmp/crumb
echo "Jenkins configured; first build queued"
