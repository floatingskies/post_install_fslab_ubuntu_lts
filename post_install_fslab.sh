#!/bin/bash


echo Instalando wget, curl, e nodejs e NVM""
sudo apt install wget curl git
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
\. "$HOME/.nvm/nvm.sh"
nvm install 24
node -v # Should print "v24.14.0".
npm -v # Should print "11.9.0".


echo "Instalando o VSCode via .snap"
sudo snap refresh
sudo snap install code --classic

echo "Instalando aplicativos de desenvolvimento via Snap"
sudo snap refresh
sudo snap install insomnia --classic
sudo snap install datagrip --classic


echo "Instalando Docker via repositorio snap oficial"
sudo snap refresh
sudo snap install docker
