wget snell-shadowtls-onekey.sh '这里换成你下载到的新脚本'
chmod +x snell-shadowtls-onekey.sh

普通 NAT：公网 20086 → 内部 20086
PUBLIC_PORT=20086 sh snell-shadowtls-onekey.sh install

你前面说的情况：公网 20086 → 内部 443

这版可以直接这样装：

PUBLIC_PORT=443 CLIENT_PORT=20086 sh snell-shadowtls-onekey.sh install

如果 NAT 入口地址不是出口 IP

比如服务商给你的是入口域名或固定入口 IP：

SERVER_ADDR=入口IP或域名 PUBLIC_PORT=443 CLIENT_PORT=20086 sh snell-shadowtls-onekey.sh install
查看二维码
sh snell-shadowtls-onekey.sh qr
查看状态/日志
sh snell-shadowtls-onekey.sh status
sh snell-shadowtls-onekey.sh logs

这版以后你 NAT 机最关键就记住一句：
PUBLIC_PORT 填内部监听端口，CLIENT_PORT 填外部公网端口。
