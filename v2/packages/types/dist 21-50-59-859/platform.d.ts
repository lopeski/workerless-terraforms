export interface QuotaConfig {
    readonly requestsCpu: string;
    readonly requestsMemory: string;
    readonly limitsCpu: string;
    readonly limitsMemory: string;
    readonly pods: string;
}
export interface ContainerLimitsConfig {
    readonly defaultCpu: string;
    readonly defaultMemory: string;
    readonly defaultRequestCpu: string;
    readonly defaultRequestMemory: string;
    readonly maxCpu: string;
    readonly maxMemory: string;
}
export interface PlanConfig {
    readonly quota: QuotaConfig;
    readonly container: ContainerLimitsConfig;
    readonly maxReplicas: number;
}
export interface ComponentResourceConfig {
    readonly requests: {
        readonly cpu: string;
        readonly memory: string;
    };
    readonly limits: {
        readonly cpu: string;
        readonly memory: string;
    };
}
export interface PlatformResourceOverrides {
    readonly externalSecrets?: ComponentResourceConfig;
    readonly keda?: ComponentResourceConfig;
    readonly kyverno?: ComponentResourceConfig;
    readonly prometheus?: ComponentResourceConfig;
    readonly alertmanager?: ComponentResourceConfig;
    readonly grafana?: ComponentResourceConfig;
}
export interface MonitoringStorageConfig {
    readonly prometheusSize: string;
    readonly prometheusRetention: string;
    readonly prometheusRetentionSize?: string;
    readonly prometheusEvaluationInterval?: string;
    readonly alertmanagerSize: string;
    readonly grafanaSize: string;
    readonly storageClassName: string;
}
//# sourceMappingURL=platform.d.ts.map