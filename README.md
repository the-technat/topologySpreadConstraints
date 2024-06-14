# topologySpreadConstraints

## Lab env

```bash
eksctl create cluster -f eks.yaml
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade -i cluster-autoscaler -n cluster-autoscaler autoscaler/cluster-autoscaler -f cluster-autoscaler.yaml
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm upgrade -i podinfo --create-namespace -n podinfo podinfo/podinfo -f podinfo.yaml
```