import React, { useContext, useEffect, useState } from "react";
import { Button, Checkbox, Divider, Form, Input, InputNumber, message, Select, Space, Switch, Tooltip, Typography } from "antd";
import { PageLayout, PageHeader, ControlContext } from "@clusterio/web_ui";
import * as lib from "@clusterio/lib";
import * as messages from "../../messages";

const S = messages.DEFAULT_SURFACE_SETTINGS;

const CB: React.CSSProperties = { marginBottom: 2 };
const FI: React.CSSProperties = { marginBottom: 8 };
const DIV: React.CSSProperties = { margin: "8px 0" };

type SurfaceSettings = Record<string, unknown>;
type SettingsState = {
	surfaceSettings: Record<string, SurfaceSettings>;
	globalSettings: Record<string, unknown>;
	mode: string;
};

export default function SettingsPage() {
	const control = useContext(ControlContext);
	const [state, setState] = useState<SettingsState | null>(null);
	const [selectedSurface, setSelectedSurface] = useState<string>("(global)");
	const [form] = Form.useForm();
	const [saving, setSaving] = useState(false);
	const [loading, setLoading] = useState(false);
	const [togglingMode, setTogglingMode] = useState(false);
	const [messageApi, contextHolder] = message.useMessage();

	const toggleMode = React.useCallback(async (checked: boolean) => {
		if (togglingMode) return;
		const newMode = checked ? "controller" : "in_game";
		setTogglingMode(true);
		try {
			await control.send(new lib.ControllerConfigSetFieldRequest("ctron_plugin.settings_sync_mode", newMode));
			const result = await control.send(new messages.CtronSettingsGet()) as any;
			setState(result);
		} catch (err) {
			console.error("Failed to toggle settings mode", err);
			messageApi.error("Failed to toggle settings mode");
		} finally {
			setTogglingMode(false);
		}
	}, [control, togglingMode]);

	const fetchSettings = React.useCallback(() => {
		setLoading(true);
		control.send(new messages.CtronSettingsGet()).then((result: any) => {
			setState(result);
		}).catch(console.error).finally(() => setLoading(false));
	}, [control]);

	useEffect(() => { fetchSettings(); }, [fetchSettings]);

	useEffect(() => {
		if (!state) return;
		const s = selectedSurface === "(global)" ? {} : (state.surfaceSettings[selectedSurface] ?? {});
		form.setFieldsValue({
			construction_job_toggle: Boolean((s as any).construction_job_toggle ?? S.construction_job_toggle),
			rebuild_job_toggle: Boolean((s as any).rebuild_job_toggle ?? S.rebuild_job_toggle),
			deconstruction_job_toggle: Boolean((s as any).deconstruction_job_toggle ?? S.deconstruction_job_toggle),
			upgrade_job_toggle: Boolean((s as any).upgrade_job_toggle ?? S.upgrade_job_toggle),
			repair_job_toggle: Boolean((s as any).repair_job_toggle ?? S.repair_job_toggle),
			destroy_job_toggle: Boolean((s as any).destroy_job_toggle ?? S.destroy_job_toggle),
			zone_restriction_job_toggle: Boolean((s as any).zone_restriction_job_toggle ?? S.zone_restriction_job_toggle),
			horde_mode: Boolean((s as any).horde_mode ?? S.horde_mode),
			desired_robot_count: Number((s as any).desired_robot_count ?? S.desired_robot_count),
			ammo_count: Number((s as any).ammo_count ?? S.ammo_count),
			atomic_ammo_count: Number((s as any).atomic_ammo_count ?? S.atomic_ammo_count),
			destroy_min_cluster_size: Number((s as any).destroy_min_cluster_size ?? S.destroy_min_cluster_size),
			minion_count: Number((s as any).minion_count ?? S.minion_count),
			desired_robot_name_name: (s as any).desired_robot_name?.name ?? S.desired_robot_name.name,
			desired_robot_name_quality: (s as any).desired_robot_name?.quality ?? S.desired_robot_name.quality,
			repair_tool_name_name: (s as any).repair_tool_name?.name ?? S.repair_tool_name.name,
			repair_tool_name_quality: (s as any).repair_tool_name?.quality ?? S.repair_tool_name.quality,
			ammo_name_name: (s as any).ammo_name?.name ?? S.ammo_name.name,
			ammo_name_quality: (s as any).ammo_name?.quality ?? S.ammo_name.quality,
			atomic_ammo_name_name: (s as any).atomic_ammo_name?.name ?? S.atomic_ammo_name.name,
			atomic_ammo_name_quality: (s as any).atomic_ammo_name?.quality ?? S.atomic_ammo_name.quality,
		});
	}, [state, selectedSurface, form]);

	const isControllerMode = state?.mode === "controller";

	const onSave = async () => {
		const values = form.getFieldsValue();
		const surfaceName = selectedSurface === "(global)" ? null : selectedSurface;
		const settings: Record<string, unknown> = {
			construction_job_toggle: Boolean(values.construction_job_toggle),
			rebuild_job_toggle: Boolean(values.rebuild_job_toggle),
			deconstruction_job_toggle: Boolean(values.deconstruction_job_toggle),
			upgrade_job_toggle: Boolean(values.upgrade_job_toggle),
			repair_job_toggle: Boolean(values.repair_job_toggle),
			destroy_job_toggle: Boolean(values.destroy_job_toggle),
			zone_restriction_job_toggle: Boolean(values.zone_restriction_job_toggle),
			horde_mode: Boolean(values.horde_mode),
			desired_robot_count: Number(values.desired_robot_count),
			ammo_count: Number(values.ammo_count),
			atomic_ammo_count: Number(values.atomic_ammo_count),
			destroy_min_cluster_size: Number(values.destroy_min_cluster_size),
			minion_count: Number(values.minion_count),
			desired_robot_name: { name: values.desired_robot_name_name, quality: values.desired_robot_name_quality },
			repair_tool_name: { name: values.repair_tool_name_name, quality: values.repair_tool_name_quality },
			ammo_name: { name: values.ammo_name_name, quality: values.ammo_name_quality },
			atomic_ammo_name: { name: values.atomic_ammo_name_name, quality: values.atomic_ammo_name_quality },
		};

		setSaving(true);
		try {
			await control.send(new messages.CtronSettingsSet(surfaceName, settings));
			const result = await control.send(new messages.CtronSettingsGet()) as any;
			setState(result);
		} catch (err) {
			console.error("Failed to save settings", err);
			messageApi.error("Failed to save settings");
		} finally {
			setSaving(false);
		}
	};

	const surfaceOptions = [
		{ value: "(global)", label: "(global)" },
		...Object.keys(state?.surfaceSettings ?? {}).map(n => ({ value: n, label: n })),
	];

	const disabled = !isControllerMode;

	return (
		<PageLayout nav={[{ name: "Constructron Settings" }]}>
			{contextHolder}
			<PageHeader
				title="Constructron Settings"
				extra={
					<Space>
						<Tooltip title="Toggle between in-game player control and web UI (controller) control">
							<Switch
								checked={isControllerMode}
								loading={togglingMode}
								onChange={toggleMode}
								disabled={loading || state === null}
								checkedChildren="Controller"
								unCheckedChildren="In-game"
							/>
						</Tooltip>
						<Button loading={loading} onClick={fetchSettings}>Refresh</Button>
					</Space>
				}
			/>
			{!loading && !isControllerMode && (
				<Typography.Paragraph type="secondary" style={{ marginBottom: 8 }}>
					Settings are currently managed in-game by players. Use the toggle above to switch to controller authority.
				</Typography.Paragraph>
			)}
			<Space style={{ marginBottom: 8 }}>
				<span>Surface:</span>
				<Select
					value={selectedSurface}
					onChange={setSelectedSurface}
					options={surfaceOptions}
					style={{ minWidth: 160 }}
					size="small"
				/>
			</Space>
			<Form form={form} layout="vertical" size="small">
				{selectedSurface === "(global)" && isControllerMode && (
					<Typography.Paragraph type="warning" style={{ marginBottom: 6 }}>
						Saving will apply these settings to all known surfaces on all instances.
					</Typography.Paragraph>
				)}
				<Divider style={DIV}>Job Types</Divider>
				<Form.Item name="construction_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Construction Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="rebuild_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Rebuild Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="deconstruction_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Deconstruction Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="upgrade_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Upgrade Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="repair_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Repair Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="destroy_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Destroy Jobs</Checkbox>
				</Form.Item>
				<Form.Item name="zone_restriction_job_toggle" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Zone Restriction</Checkbox>
				</Form.Item>
				<Form.Item name="horde_mode" valuePropName="checked" style={CB}>
					<Checkbox disabled={disabled}>Horde Mode</Checkbox>
				</Form.Item>
				<Divider style={DIV}>Robot Settings</Divider>
				<Form.Item name="desired_robot_count" label="Desired Robot Count" style={FI}>
					<InputNumber min={0} max={10000} disabled={disabled} />
				</Form.Item>
				<Form.Item label="Robot Name" style={FI}>
					<Space>
						<Form.Item name="desired_robot_name_name" noStyle>
							<Input disabled={disabled} placeholder="name" />
						</Form.Item>
						<Form.Item name="desired_robot_name_quality" noStyle>
							<Input disabled={disabled} placeholder="quality" />
						</Form.Item>
					</Space>
				</Form.Item>
				<Form.Item label="Repair Tool" style={FI}>
					<Space>
						<Form.Item name="repair_tool_name_name" noStyle>
							<Input disabled={disabled} placeholder="name" />
						</Form.Item>
						<Form.Item name="repair_tool_name_quality" noStyle>
							<Input disabled={disabled} placeholder="quality" />
						</Form.Item>
					</Space>
				</Form.Item>
				<Divider style={DIV}>Destroy Job Settings</Divider>
				<Form.Item name="destroy_min_cluster_size" label="Min Cluster Size" style={FI}>
					<InputNumber min={1} max={100} disabled={disabled} />
				</Form.Item>
				<Form.Item name="minion_count" label="Minion Count" style={FI}>
					<InputNumber min={0} max={100} disabled={disabled} />
				</Form.Item>
				<Form.Item label="Ammo" style={FI}>
					<Space>
						<Form.Item name="ammo_name_name" noStyle>
							<Input disabled={disabled} placeholder="name" />
						</Form.Item>
						<Form.Item name="ammo_name_quality" noStyle>
							<Input disabled={disabled} placeholder="quality" />
						</Form.Item>
					</Space>
				</Form.Item>
				<Form.Item name="ammo_count" label="Ammo Count" style={FI}>
					<InputNumber min={0} max={8000} disabled={disabled} />
				</Form.Item>
				<Form.Item label="Atomic Ammo" style={FI}>
					<Space>
						<Form.Item name="atomic_ammo_name_name" noStyle>
							<Input disabled={disabled} placeholder="name" />
						</Form.Item>
						<Form.Item name="atomic_ammo_name_quality" noStyle>
							<Input disabled={disabled} placeholder="quality" />
						</Form.Item>
					</Space>
				</Form.Item>
				<Form.Item name="atomic_ammo_count" label="Atomic Ammo Count" style={FI}>
					<InputNumber min={0} max={1000} disabled={disabled} />
				</Form.Item>
				{isControllerMode && (
					<Form.Item style={{ marginTop: 8, marginBottom: 0 }}>
						<Button type="primary" loading={saving} onClick={onSave}>Save</Button>
					</Form.Item>
				)}
			</Form>
		</PageLayout>
	);
}
