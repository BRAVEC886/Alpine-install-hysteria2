# Alpine-install-hysteria2

自用Alpine系统下一键安装hysteria2脚本  
脚本为zrlhk作者的脚本修改，支持对Alpine系统的架构检测和一键安装，适用于Nat机器  

# 一键安装

```bash
wget -O hy2.sh https://raw.githubusercontent.com/BRAVEC886/Alpine-install-hysteria2/refs/heads/main/hy2.sh && sh hy2.sh
```

# 配置信息

默认端口：20000  
SNI：bing.com  
自动输出URL方便导入，如果脚本检测没有CAP_NET_ADMIN权限，则无法在机器内设置端口跳跃，需要去管理界面增加端口映射  
友情链接：https://github.com/zrlhk/alpine-hysteria2  
