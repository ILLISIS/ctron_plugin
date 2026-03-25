import React, { useContext, useMemo } from "react";
import { Table, Tabs, Tag, Typography } from "antd";

import { ControlContext, PageHeader, PageLayout, useInstances } from "@clusterio/web_ui";
import { WebPlugin } from "..";
import SettingsPage from "./SettingsPage";

type Row = {
	key: string;
	instanceId: number;
	instanceName: string;
	publisher: boolean;
	subscriber: boolean;
	serviceStationCount: number | null;
};

function InstancesTab() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("ctron_plugin") as WebPlugin;
	const statusByInstance = plugin.useServiceStationStatusByInstance();
	const [instances] = useInstances();

	const rows = useMemo(() => {
		return [...instances.values()]
			.map((inst) => {
				const instanceId = inst.id;
				const status = statusByInstance.get(instanceId);
				const subscriber = Boolean(status?.isSubscriber);
				const count = status?.serviceStationCount;
				return {
					key: String(instanceId),
					instanceId,
					instanceName: inst.name ?? "",
					publisher: !subscriber,
					subscriber,
					serviceStationCount: typeof count === "number" ? count : null,
				} satisfies Row;
			})
			.sort((a, b) => a.instanceId - b.instanceId);
	}, [instances, statusByInstance]);

	return (
		<div style={{ padding: 16 }}>
			<Typography.Paragraph type="secondary">
				Publishers generate Constructron jobs and send them to the controller.
				Subscribers have at least one Constructron service station and can claim jobs from the queue.
			</Typography.Paragraph>
			<Table<Row>
				rowKey={(r: Row) => r.key}
				dataSource={rows}
				pagination={false}
				columns={[
					{
						title: "Instance",
						key: "instance",
						render: (_value: unknown, record: Row) =>
							record.instanceName || String(record.instanceId),
					},
					{
						title: "Publisher",
						key: "publisher",
						render: (_value: unknown, record: Row) =>
							record.publisher ? <Tag color="green">Yes</Tag> : <Tag>No</Tag>,
					},
					{
						title: "Subscriber",
						key: "subscriber",
						render: (_value: unknown, record: Row) =>
							record.subscriber ? <Tag color="blue">Yes</Tag> : <Tag>No</Tag>,
					},
					{
						title: "Service stations",
						dataIndex: "serviceStationCount",
						key: "serviceStationCount",
						render: (value: Row["serviceStationCount"]) => (value == null ? "\u2014" : String(value)),
					},
				]}
			/>
		</div>
	);
}

export default function InstanceRolesPage() {
	return (
		<PageLayout nav={[{ name: "Constructron" }]}>
			<PageHeader title="Constructron" />
			<Tabs
				defaultActiveKey="instances"
				style={{ padding: "0 16px" }}
				items={[
					{ key: "instances", label: "Instances", children: <InstancesTab /> },
					{ key: "settings", label: "Settings", children: <SettingsPage embedded /> },
				]}
			/>
		</PageLayout>
	);
}
