# aws bastion host

It's a simple bash script to setup bastion host and internal host in aws cloud. It creates custom VPC, two subnets (public and private), internet gateway, two secure groups (for bastion and internal) and two instances (bastion host and internal host), append hosts config in ~/.ssh/config file. 

# Dependencies
* Python
* aws cli
* jq
 
# Usage
Execute script
```
bash setup_bastion.sh
```

*Script is not repeatable.*

## License

**[MIT License](LICENSE)**

Copyright (c) 2019 [ltblueberry](https://github.com/ltblueberry)