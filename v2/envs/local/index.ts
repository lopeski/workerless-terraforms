import * as pulumi from "@pulumi/pulumi";
import { CreateLocalClusterCommand } from "@workerless/cluster-local";
import type { LocalClusterConfig } from "@workerless/types";

const config = new pulumi.Config();

const clusterConfig: LocalClusterConfig = {
  clusterName: config.get("clusterName") ?? "local-rock",
  apiPort: config.getNumber("apiPort") ?? 6550,
  servers: config.getNumber("servers") ?? 1,
  agents: config.getNumber("agents") ?? 1,
};

const cluster = new CreateLocalClusterCommand("local-cluster", {
  config: clusterConfig,
});

export const clusterName = cluster.clusterName;
export const kubeContext = pulumi.output(`k3d-${clusterConfig.clusterName}`);
export const kubeconfigPath = pulumi.output("~/.kube/config");
