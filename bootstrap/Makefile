.PHONY: up down destroy status inventory ssh

up:        ## cria rede, baixa imagem, sobe as VMs e gera o inventário
	./bootstrap.sh up
down:      ## desliga as VMs (mantém discos)
	./bootstrap.sh down
destroy:   ## remove VMs, discos e rede do lab
	./bootstrap.sh destroy
status:
	./bootstrap.sh status
inventory:
	./bootstrap.sh inventory
ssh:       ## make ssh VM=desafio-cp1
	./bootstrap.sh ssh $(VM)
