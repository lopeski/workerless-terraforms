import * as pulumi from "@pulumi/pulumi";
import * as kubernetes from "@pulumi/kubernetes";
import type { EgressRule } from "@workerless/types";

export interface CreateNetworkPoliciesCommandArgs {
  readonly provider: kubernetes.Provider;
  readonly kedaNamespace: kubernetes.core.v1.Namespace;
  readonly monitoringNamespace: kubernetes.core.v1.Namespace;
  readonly clusterServiceCidr: string;
  readonly eventSourceEgressRules: readonly EgressRule[];
}

export class CreateNetworkPoliciesCommand extends pulumi.ComponentResource {
  constructor(
    name: string,
    args: CreateNetworkPoliciesCommandArgs,
    opts?: pulumi.ComponentResourceOptions,
  ) {
    super("workerless:platform:CreateNetworkPoliciesCommand", name, {}, opts);

    const defaultOpts: pulumi.ResourceOptions = {
      parent: this,
      provider: args.provider,
    };

    // KEDA: default deny
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-keda-default-deny`,
      {
        metadata: { name: "default-deny-all", namespace: "keda" },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress", "Egress"],
        },
      },
      { ...defaultOpts, dependsOn: [args.kedaNamespace] },
    );

    // KEDA: allow ingress from monitoring and kyverno for metrics scraping
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-keda-allow-ingress`,
      {
        metadata: { name: "allow-ingress-monitoring-kyverno", namespace: "keda" },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress"],
          ingress: [
            {
              from: [
                {
                  namespaceSelector: {
                    matchExpressions: [
                      {
                        key: "kubernetes.io/metadata.name",
                        operator: "In",
                        values: ["monitoring", "kyverno"],
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      },
      { ...defaultOpts, dependsOn: [args.kedaNamespace] },
    );

    const kedaEgressRules: kubernetes.types.input.networking.v1.NetworkPolicyEgressRule[] =
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
          ports: [{ port: 6443, protocol: "TCP" }],
          to: [{ ipBlock: { cidr: args.clusterServiceCidr } }],
        },
        {
          to: [
            {
              namespaceSelector: {
                matchLabels: { "kubernetes.io/metadata.name": "keda" },
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

    // KEDA: allow egress to DNS, API server, self, and event sources
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-keda-egress`,
      {
        metadata: { name: "allow-egress", namespace: "keda" },
        spec: {
          podSelector: {},
          policyTypes: ["Egress"],
          egress: kedaEgressRules,
        },
      },
      { ...defaultOpts, dependsOn: [args.kedaNamespace] },
    );

    // Monitoring: default deny
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-monitoring-default-deny`,
      {
        metadata: { name: "default-deny-all", namespace: "monitoring" },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress", "Egress"],
        },
      },
      { ...defaultOpts, dependsOn: [args.monitoringNamespace] },
    );

    // Monitoring: allow ingress only from monitoring and kyverno namespaces
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-monitoring-allow-ingress`,
      {
        metadata: { name: "allow-ingress-internal", namespace: "monitoring" },
        spec: {
          podSelector: {},
          policyTypes: ["Ingress"],
          ingress: [
            {
              from: [
                {
                  namespaceSelector: {
                    matchExpressions: [
                      {
                        key: "kubernetes.io/metadata.name",
                        operator: "In",
                        values: ["monitoring", "kyverno"],
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      },
      { ...defaultOpts, dependsOn: [args.monitoringNamespace] },
    );

    // Monitoring: allow egress to all namespaces (for scraping), DNS, API server
    new kubernetes.networking.v1.NetworkPolicy(
      `${name}-monitoring-egress`,
      {
        metadata: { name: "allow-egress", namespace: "monitoring" },
        spec: {
          podSelector: {},
          policyTypes: ["Egress"],
          egress: [
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
              ports: [{ port: 6443, protocol: "TCP" }],
              to: [{ ipBlock: { cidr: args.clusterServiceCidr } }],
            },
            {
              to: [{ namespaceSelector: {} }],
            },
          ],
        },
      },
      { ...defaultOpts, dependsOn: [args.monitoringNamespace] },
    );

    this.registerOutputs({});
  }
}
