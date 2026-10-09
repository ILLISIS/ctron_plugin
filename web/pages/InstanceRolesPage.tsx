import React, { useContext, useMemo } from "react";
import { Table, Tabs, Typography } from "antd";

import { ControlContext, PageHeader, PageLayout, useInstances } from "@clusterio/web_ui";
import { WebPlugin } from "..";
import SettingsPage from "./SettingsPage";

type Row = {
	key: string;
	instanceId: number;
	instanceName: string;
	/** "nauvis: 2, gleba: 1": the surfaces this instance subscribes on, by its service stations there. */
	stations: string;
};

/** Spec §8's station view: per instance, its service stations by surface; it publishes on every other surface. */
function InstancesTab() {
	const control = useContext(ControlContext);
	const plugin = control.plugins.get("ctron_plugin") as WebPlugin;
	const statusByInstance = plugin.useServiceStationStatusByInstance();
	const [instances] = useInstances();

	const rows = useMemo(() => [...instances.values()]
		.map((inst) => {
			const stations = Object.entries(statusByInstance.get(inst.id)?.stations ?? {})
				.map(([surface, count]) => `${surface}: ${count}`).join(", ");
			return { key: String(inst.id), instanceId: inst.id, instanceName: inst.name ?? "", stations } satisfies Row;
		})
		.sort((a, b) => a.instanceId - b.instanceId), [instances, statusByInstance]);
	const subscribed = [...new Set([...statusByInstance.values()].flatMap(s => Object.keys(s.stations)))].sort();

	return (
		<div style={{ padding: 16 }}>
			<Typography.Paragraph type="secondary">
				An instance subscribes on each surface where it has service stations: it builds that surface&apos;s
				jobs itself and claims others&apos; there, oldest first. On its other surfaces it publishes: its jobs go
				to the controller while some instance subscribes on that surface. Surfaces with a subscriber:{" "}
				{subscribed.length ? subscribed.join(", ") : "none"}.
			</Typography.Paragraph>
			<Table<Row>
				rowKey={(r: Row) => r.key}
				dataSource={rows}
				pagination={false}
				columns={[
					{
						title: "Instance",
						key: "instance",
						render: (_value: unknown, record: Row) => record.instanceName || String(record.instanceId),
					},
					{
						title: "Service stations by surface",
						dataIndex: "stations",
						key: "stations",
						render: (value: string) => value || "— (publishes on every surface)",
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
