import React, { useCallback, useContext, useEffect, useMemo, useSyncExternalStore } from "react";

import { BaseWebPlugin, ControlContext } from "@clusterio/web_ui";
import * as lib from "@clusterio/lib";

import * as messages from "../messages";
import InstanceRolesPage from "./pages/InstanceRolesPage";

export class WebPlugin extends BaseWebPlugin {
	subscriber!: lib.EventSubscriber<typeof messages.ConstructronJobUpdate>;
	serviceStationSubscriber!: lib.EventSubscriber<typeof messages.InstanceServiceStationStatusStream>;

	async init() {
		this.subscriber = new lib.EventSubscriber(messages.ConstructronJobUpdate, this.control);
		this.serviceStationSubscriber = new lib.EventSubscriber(messages.InstanceServiceStationStatusStream, this.control);
		this.pages = [
			{
				path: "/ctron_plugin",
				sidebarName: "Constructron",
				permission: "ctron_plugin.jobs.read",
				content: <InstanceRolesPage />,
			},
		];
	}

	useServiceStationStatusByInstance() {
		const control = useContext(ControlContext);

		// Keep subscription alive.
		useEffect(() => {
			let unsubscribe: undefined | (() => void);
			try {
				unsubscribe = this.serviceStationSubscriber.subscribe(() => { /* noop */ });
			} catch {
				// ignore
			}
			return () => unsubscribe?.();
		}, [control]);

		const subscribe = useCallback(
			(cb: () => void) => this.serviceStationSubscriber.subscribe((_event, _synced) => cb()),
			[control]
		);

		const snapshot = useSyncExternalStore(
			subscribe,
			() => this.serviceStationSubscriber.getSnapshot(),
		) as readonly [ReadonlyMap<string | number, Readonly<messages.InstanceServiceStationStatus>>, boolean];

		return useMemo(() => {
			const [values] = snapshot;
			const map = new Map<number, Readonly<messages.InstanceServiceStationStatus>>();
			for (const v of values.values()) {
				map.set(v.instanceId, v);
			}
			return map;
		}, [snapshot]);
	}

	useJobs() {
		const control = useContext(ControlContext);

		// Keep subscription alive.
		useEffect(() => {
			let unsubscribe: undefined | (() => void);
			try {
				unsubscribe = this.subscriber.subscribe(() => { /* noop */ });
			} catch {
				// ignore
			}
			return () => unsubscribe?.();
		}, [control]);

		const subscribe = useCallback(
			(cb: () => void) => this.subscriber.subscribe((_event, _synced) => cb()),
			[control]
		);

		const snapshot = useSyncExternalStore(
			subscribe,
			() => this.subscriber.getSnapshot(),
		) as readonly [ReadonlyMap<string | number, Readonly<messages.ConstructronJobValue>>, boolean];

		return useMemo(() => {
			const [values] = snapshot;
			return [...values.values()];
		}, [snapshot]);
	}
}
