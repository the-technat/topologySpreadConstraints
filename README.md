# topologySpreadConstraints

## Lab env

```bash
eksctl create cluster -f eks.yaml
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade -i cluster-autoscaler -n cluster-autoscaler autoscaler/cluster-autoscaler -f cluster-autoscaler.yaml
```