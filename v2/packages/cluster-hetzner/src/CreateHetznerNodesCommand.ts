import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as fs from "fs";

export interface CreateHetznerNodesCommandArgs {
  readonly hcloudProvider: hcloud.Provider;
  readonly networkId: pulumi.Input<number>;
  readonly firewallId: pulumi.Input<number>;
  readonly serverType: string;
  readonly workerServerType: string;
  readonly location: string;
  readonly k3sVersion: string;
  readonly workerCount: number;
  readonly sshPublicKeyPath: string;
  readonly etcdSnapshotSchedule: string;
  readonly etcdSnapshotRetention: number;
}

const BOOTSTRAP_PRIVATE_IP = "10.10.1.2";
const JOINER_BASE_IP = "10.10.1.";
const WORKER_BASE_IP_START = 20;

function buildBootstrapUserData(k3sVersion: string, snapshotSchedule: string, snapshotRetention: number): string {
  return `#!/bin/bash
set -e
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3sVersion}" sh -s - server \
  --cluster-init \
  --tls-san "${BOOTSTRAP_PRIVATE_IP}" \
  --node-taint "CriticalAddonsOnly=true:NoSchedule" \
  --disable traefik \
  --flannel-iface eth1 \
  --etcd-snapshot-schedule-cron "${snapshotSchedule}" \
  --etcd-snapshot-retention ${snapshotRetention}
`;
}

function buildJoinerUserData(k3sVersion: string, index: number): string {
  const privateIp = `${JOINER_BASE_IP}${3 + index}`;
  return `#!/bin/bash
set -e
until curl -sk https://${BOOTSTRAP_PRIVATE_IP}:6443/healthz; do sleep 5; done
TOKEN=$(ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa root@${BOOTSTRAP_PRIVATE_IP} cat /var/lib/rancher/k3s/server/node-token)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3sVersion}" K3S_TOKEN="$TOKEN" sh -s - server \
  --server https://${BOOTSTRAP_PRIVATE_IP}:6443 \
  --tls-san "${privateIp}" \
  --node-taint "CriticalAddonsOnly=true:NoSchedule" \
  --disable traefik \
  --flannel-iface eth1
`;
}

function buildWorkerUserData(k3sVersion: string): string {
  return `#!/bin/bash
set -e
until curl -sk https://${BOOTSTRAP_PRIVATE_IP}:6443/healthz; do sleep 5; done
TOKEN=$(ssh -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa root@${BOOTSTRAP_PRIVATE_IP} cat /var/lib/rancher/k3s/server/node-token)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3sVersion}" K3S_TOKEN="$TOKEN" K3S_URL="https://${BOOTSTRAP_PRIVATE_IP}:6443" sh -s - agent \
  --flannel-iface eth1 \
  --node-label "workerless.io/node-pool=workers"
`;
}

export interface HetznerNodes {
  readonly bootstrap: hcloud.Server;
  readonly joiners: readonly hcloud.Server[];
  readonly workers: readonly hcloud.Server[];
  readonly sshKey: hcloud.SshKey;
}

export class CreateHetznerNodesCommand extends pulumi.ComponentResource {
  public readonly bootstrap: hcloud.Server;
  public readonly joiners: readonly hcloud.Server[];
  public readonly workers: readonly hcloud.Server[];
  public readonly bootstrapPublicIp: pulumi.Output<string>;
  public readonly bootstrapPrivateIp: string;

  constructor(
    name: string,
    args: CreateHetznerNodesCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:CreateHetznerNodesCommand", name, {}, opts);

    const sshPublicKey = fs.readFileSync(args.sshPublicKeyPath, "utf8").trim();
    const providerOpt = { parent: this, provider: args.hcloudProvider };

    const sshKey = new hcloud.SshKey(
      `${name}-ssh-key`,
      {
        name: "workerless-key",
        publicKey: sshPublicKey,
        labels: { "workerless.io/managed-by": "pulumi" },
      },
      providerOpt,
    );

    const commonServerArgs = {
      serverType: args.serverType,
      image: "ubuntu-24.04",
      location: args.location,
      sshKeys: [sshKey.name],
      labels: { "workerless.io/managed-by": "pulumi" },
      firewallIds: [pulumi.output(args.firewallId)] as pulumi.Input<pulumi.Input<number>[]>,
      networks: [
        {
          networkId: pulumi.output(args.networkId),
        },
      ],
    };

    this.bootstrap = new hcloud.Server(
      `${name}-bootstrap`,
      {
        ...commonServerArgs,
        name: "k3s-hetzner-rock-0",
        userData: buildBootstrapUserData(
          args.k3sVersion,
          args.etcdSnapshotSchedule,
          args.etcdSnapshotRetention,
        ),
      },
      { ...providerOpt, dependsOn: [sshKey] },
    );

    const joiners: hcloud.Server[] = [];
    for (let i = 0; i < 2; i++) {
      const joiner = new hcloud.Server(
        `${name}-joiner-${i}`,
        {
          ...commonServerArgs,
          name: `k3s-hetzner-rock-${i + 1}`,
          userData: buildJoinerUserData(args.k3sVersion, i),
        },
        { ...providerOpt, dependsOn: [this.bootstrap] },
      );
      joiners.push(joiner);
    }
    this.joiners = joiners;

    const workers: hcloud.Server[] = [];
    for (let i = 0; i < args.workerCount; i++) {
      const worker = new hcloud.Server(
        `${name}-worker-${i}`,
        {
          serverType: args.workerServerType,
          image: "ubuntu-24.04",
          location: args.location,
          sshKeys: [sshKey.name],
          labels: {
            "workerless.io/managed-by": "pulumi",
            "workerless.io/node-pool": "workers",
          },
          name: `k3s-hetzner-worker-${i}`,
          userData: buildWorkerUserData(args.k3sVersion),
          firewallIds: [pulumi.output(args.firewallId).apply((id) => id)],
          networks: [
            {
              networkId: pulumi.output(args.networkId).apply((id) => id),
              ip: `${JOINER_BASE_IP}${WORKER_BASE_IP_START + i}`,
            },
          ],
        },
        { ...providerOpt, dependsOn: [...joiners] },
      );
      workers.push(worker);
    }
    this.workers = workers;

    this.bootstrapPublicIp = this.bootstrap.ipv4Address;
    this.bootstrapPrivateIp = BOOTSTRAP_PRIVATE_IP;

    this.registerOutputs({
      bootstrapPublicIp: this.bootstrapPublicIp,
      bootstrapPrivateIp: this.bootstrapPrivateIp,
    });
  }
}
