import * as pulumi from "@pulumi/pulumi";
import { HetznerClusterService } from "@workerless/cluster-hetzner";
import type { HetznerClusterConfig } from "@workerless/types";

const config = new pulumi.Config();

const clusterConfig: HetznerClusterConfig = {
  sshPublicKeyPath:
    config.get("sshPublicKeyPath") ?? `${process.env["HOME"]}/.ssh/id_rsa.pub`,
  sshPrivateKeyPath:
    config.get("sshPrivateKeyPath") ?? `${process.env["HOME"]}/.ssh/id_rsa`,
  k3sVersion: config.get("k3sVersion") ?? "v1.30.5+k3s1",
  serverType: config.get("serverType") ?? "cax11",
  workerServerType: config.get("workerServerType") ?? "cax21",
  workerCount: config.getNumber("workerCount") ?? 2,
  location: config.get("location") ?? "ash",
  networkZone: config.get("networkZone") ?? "us-east",
  adminCidrs: config.requireObject<string[]>("adminCidrs"),
  etcdSnapshotSchedule:
    config.get("etcdSnapshotSchedule") ?? "0 */6 * * *",
  etcdSnapshotRetention: config.getNumber("etcdSnapshotRetention") ?? 14,
};

const hcloudToken = config.requireSecret("hcloudToken");

const cluster = new HetznerClusterService("hetzner-cluster", {
  hcloudToken,
  config: clusterConfig,
});

export const kubeHost = cluster.kubeHost;
export const kubeCa = cluster.kubeCa;
export const kubeClientCert = cluster.kubeClientCert;
export const kubeClientKey = cluster.kubeClientKey;
export const kubeconfig = cluster.kubeconfig;
