#Install python and AWS CLI:

sudo apt update && sudo apt upgrade -y
sudo apt install python3 python3-pip -y
sudo apt install awscli -y
aws --version

pip3 install boto3
pip3 install scanpy

#Install Docker:
sudo apt update && sudo apt upgrade -y
sudo apt install apt-transport-https ca-certificates gnupg lsb-release -y
wget -qO- https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io -y
docker --version
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
