import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import type { HetznerClusterConfig } from "@workerless/types";
import { CreateHetznerNetworkCommand } from "./CreateHetznerNetworkCommand";
import { CreateHetznerFirewallCommand } from "./CreateHetznerFirewallCommand";
import { CreateHetznerNodesCommand } from "./CreateHetznerNodesCommand";
import { WaitForNodesCommand } from "./WaitForNodesCommand";
import { FetchKubeconfigCommand } from "./FetchKubeconfigCommand";

export interface HetznerClusterServiceArgs {
  readonly hcloudToken: pulumi.Input<string>;
  readonly config: HetznerClusterConfig;
}

const NETWORK_CIDR = "10.10.0.0/16";
const SUBNET_CIDR = "10.10.1.0/24";

export class HetznerClusterService extends pulumi.ComponentResource {
  public readonly kubeconfig: pulumi.Output<string>;
  public readonly kubeHost: pulumi.Output<string>;
  public readonly kubeCa: pulumi.Output<string>;
  public readonly kubeClientCert: pulumi.Output<string>;
  public readonly kubeClientKey: pulumi.Output<string>;

  constructor(
    name: string,
    args: HetznerClusterServiceArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:HetznerClusterService", name, {}, opts);

    const { config } = args;

    const hcloudProvider = new hcloud.Provider(
      `${name}-hcloud-provider`,
      { token: args.hcloudToken },
      { parent: this },
    );

    const network = new CreateHetznerNetworkCommand(
      `${name}-network`,
      {
        hcloudProvider,
        networkZone: config.networkZone,
        networkCidr: NETWORK_CIDR,
        subnetCidr: SUBNET_CIDR,
      },
      { parent: this },
    );

    const firewall = new CreateHetznerFirewallCommand(
      `${name}-firewall`,
      {
        hcloudProvider,
        adminCidrs: config.adminCidrs,
        internalCidr: NETWORK_CIDR,
      },
      { parent: this },
    );

    const nodes = new CreateHetznerNodesCommand(
      `${name}-nodes`,
      {
        hcloudProvider,
        networkId: network.networkId,
        firewallId: firewall.firewall.id.apply((id) => Number(id)),
        serverType: config.serverType,
        workerServerType: config.workerServerType,
        location: config.location,
        k3sVersion: config.k3sVersion,
        workerCount: config.workerCount,
        sshPublicKeyPath: config.sshPublicKeyPath,
        etcdSnapshotSchedule: config.etcdSnapshotSchedule,
        etcdSnapshotRetention: config.etcdSnapshotRetention,
      },
      { parent: this, dependsOn: [network, firewall] },
    );

    const totalNodeCount = 3 + config.workerCount;

    const waitReady = new WaitForNodesCommand(
      `${name}-wait`,
      {
        bootstrapPublicIp: nodes.bootstrapPublicIp,
        sshPrivateKeyPath: config.sshPrivateKeyPath,
        expectedNodeCount: totalNodeCount,
      },
      { parent: this, dependsOn: [nodes] },
    );

    const kubeconfig = new FetchKubeconfigCommand(
      `${name}-kubeconfig`,
      {
        bootstrapPublicIp: nodes.bootstrapPublicIp,
        sshPrivateKeyPath: config.sshPrivateKeyPath,
      },
      { parent: this, dependsOn: [waitReady] },
    );

    this.kubeconfig = kubeconfig.kubeconfig;
    this.kubeHost = kubeconfig.kubeHost;
    this.kubeCa = kubeconfig.kubeCa;
    this.kubeClientCert = kubeconfig.kubeClientCert;
    this.kubeClientKey = kubeconfig.kubeClientKey;

    this.registerOutputs({
      kubeconfig: this.kubeconfig,
      kubeHost: this.kubeHost,
      kubeCa: this.kubeCa,
      kubeClientCert: this.kubeClientCert,
      kubeClientKey: this.kubeClientKey,
    });
  }
}
