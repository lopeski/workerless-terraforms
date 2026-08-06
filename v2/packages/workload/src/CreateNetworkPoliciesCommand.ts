import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { EgressRule } from "@workerless/types";

export interface CreateWorkloadNetworkPoliciesCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly namespace: kubernetes.core.v1.Namespace;
  readonly eventSourceEgressRules: readonly EgressRule[];
}

export class CreateWorkloadNetworkPoliciesCommand extends pulumi.ComponentResource {
  constructor(
    name: string,
    args: CreateWorkloadNetworkPoliciesCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super(
      "workerless:workload:CreateWorkloadNetworkPoliciesCommand",
      name,
      {},
      opts,
    );

    const ns = args.namespace.metadata.name;
    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
      dependsOn: [args.namespace],
    };

    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-default-deny`,
      {
        metadata: {
          name: "default-deny-all",
          namespace: ns,
        },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress", "Egress"],
        },
      },
      defaultOpts,
    );

    const egressRules: kubernetes.types.input.networking.v1.NetworkPolicyEgressRule[] =
      [
        {
          ports: [
            { port: 53, protocol: "TCP" },
            { port: 53, protocol: "UDP" },
          ],
          to: [
            {
              namespaceSelector: {
                matchLabels: { "kubernetes.io/metadata.name": "kube-system" },
              },
            },
          ],
        },
        {
          ports: [
            { port: 80, protocol: "TCP" },
            { port: 443, protocol: "TCP" },
            { port: 587, protocol: "TCP" },
            { port: 465, protocol: "TCP" },
          ],
          to: [
            {
              ipBlock: {
                cidr: "0.0.0.0/0",
                except: [
                  "10.0.0.0/8",
                  "172.16.0.0/12",
                  "192.168.0.0/16",
                  "169.254.0.0/16",
                ],
              },
            },
          ],
        },
        ...args.eventSourceEgressRules.map((rule) => ({
          to: [{ ipBlock: { cidr: rule.cidr } }],
          ports: rule.ports.map((p) => ({
            port: p.port,
            protocol: (p.protocol ?? "TCP") as "TCP" | "UDP" | "SCTP",
          })),
        })),
      ];

    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-worker-egress`,
      {
        metadata: {
          name: "worker-egress-allow",
          namespace: ns,
        },
        spec: {
          podSelector: {},
          policyTypes: ["Egress"],
          egress: egressRules,
        },
      },
      defaultOpts,
    );

    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-monitoring-scrape`,
      {
        metadata: {
          name: "allow-monitoring-scrape",
          namespace: ns,
        },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress"],
          ingress: [
            {
              from: [
                {
                  namespaceSelector: {
                    matchLabels: {
                      "kubernetes.io/metadata.name": "monitoring",
                    },
                  },
                },
              ],
            },
          ],
        },
      },
      defaultOpts,
    );

    this.registerOutputs({});
  }
}
