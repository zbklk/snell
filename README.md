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

-----------------------------------------------------------------------------------------------------------
| Shadowrocket 项目 | 填什么                             |
| --------------- | ------------------------------- |
| **类型**          | Snell                           |
| **地址**          | 你的服务器公网入口 IP / NAT 入口 IP / 域名   |
| **端口**          | 客户端连接端口，比如 `20086`              |
| **密码**          | 填 **Snell PSK**，不是 ShadowTLS 密码 |
| **版本**          | 选 `4`                           |
| **混淆**          | `none`                          |
| **插件**          | 选 `ShadowTLS` / `shadow-tls`    |
| **多路复用**        | 可以先打开；不通再关闭试试                   |
| **TCP 快速打开**    | 先关闭                             |
| **UDP 转发**      | 先关闭                             |
| **代理通过**        | 不用填                             |
| **备注**          | 随便写，比如 `NAT-Snell-STLS`         |


点“插件”之后这样填

你点图片里的：

插件 none >

进去后如果有 ShadowTLS，选择它，然后填：

插件项目	填什么
插件类型	ShadowTLS
版本	3
密码	ShadowTLS 密码
SNI / Host / Server Name	www.microsoft.com，或者你安装时设置的 TLS_DOMAIN

如果你安装脚本时是默认值，那么 SNI 一般就是：

www.microsoft.com
NAT 端口特别注意

如果你的 NAT 映射是：

公网 20086 → 内部 20086

那 Shadowrocket 端口填：

20086

如果你的 NAT 映射是：

公网 20086 → 内部 443

那 Shadowrocket 端口仍然填：

20086

因为客户端永远填 公网外部端口，不是机器内部监听端口。
