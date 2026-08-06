import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

export interface CreateHetznerFirewallCommandArgs {
  readonly hcloudProvider: hcloud.Provider;
  readonly adminCidrs: readonly string[];
  readonly internalCidr: string;
}

export class CreateHetznerFirewallCommand extends pulumi.ComponentResource {
  public readonly firewall: hcloud.Firewall;

  constructor(
    name: string,
    args: CreateHetznerFirewallCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:CreateHetznerFirewallCommand", name, {}, opts);

    const { adminCidrs, internalCidr } = args;

    this.firewall = new hcloud.Firewall(
      `${name}-fw`,
      {
        name: "workerless-firewall",
        rules: [
          {
            direction: "in",
            protocol: "tcp",
            port: "22",
            sourceIps: [...adminCidrs],
            description: "SSH from admin CIDRs",
          },
          {
            direction: "in",
            protocol: "tcp",
            port: "6443",
            sourceIps: [...adminCidrs],
            description: "Kubernetes API from admin CIDRs",
          },
          {
            direction: "in",
            protocol: "tcp",
            port: "2379-2380",
            sourceIps: [internalCidr],
            description: "etcd inter-cluster",
          },
          {
            direction: "in",
            protocol: "tcp",
            port: "10250",
            sourceIps: [internalCidr],
            description: "kubelet inter-cluster",
          },
          {
            direction: "in",
            protocol: "udp",
            port: "8472",
            sourceIps: [internalCidr],
            description: "Flannel VXLAN inter-cluster",
          },
          {
            direction: "in",
            protocol: "tcp",
            port: "51820",
            sourceIps: [internalCidr],
            description: "WireGuard inter-cluster",
          },
        ],
        labels: { "workerless.io/managed-by": "pulumi" },
      },
      { parent: this, provider: args.hcloudProvider },
    );

    this.registerOutputs({});
  }
}
