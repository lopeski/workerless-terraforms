import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

export interface CreateHetznerNetworkCommandArgs {
  readonly hcloudProvider: hcloud.Provider;
  readonly networkZone: string;
  readonly networkCidr: string;
  readonly subnetCidr: string;
}

export class CreateHetznerNetworkCommand extends pulumi.ComponentResource {
  public readonly network: hcloud.Network;
  public readonly subnet: hcloud.NetworkSubnet;
  public readonly networkId: pulumi.Output<number>;

  constructor(
    name: string,
    args: CreateHetznerNetworkCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:cluster:CreateHetznerNetworkCommand", name, {}, opts);

    const providerOpt = { parent: this, provider: args.hcloudProvider };

    this.network = new hcloud.Network(
      `${name}-net`,
      {
        name: "workerless-net",
        ipRange: args.networkCidr,
        labels: { "workerless.io/managed-by": "pulumi" },
      },
      providerOpt,
    );

    this.subnet = new hcloud.NetworkSubnet(
      `${name}-subnet`,
      {
        networkId: this.network.id.apply((id) => Number(id)),
        type: "cloud",
        networkZone: args.networkZone,
        ipRange: args.subnetCidr,
      },
      { ...providerOpt, dependsOn: [this.network] },
    );

    this.networkId = this.network.id.apply((id) => Number(id));

    this.registerOutputs({
      networkId: this.networkId,
    });
  }
}
