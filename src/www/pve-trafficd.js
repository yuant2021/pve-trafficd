/*
 * pve-trafficd web UI
 *
 *  Datacenter -> Traffic   cluster defaults and all counted NICs of the cluster
 *  VM -> Traffic           traffic, quota and limit of the VM's NICs
 *
 * Loaded after pvemanagerlib.js through a script tag pve-trafficd adds to
 * /usr/share/pve-manager/index.html.tpl.
 */
Ext.ns('PVE.trafficd');

PVE.trafficd.Utils = {
    // built-in defaults of the backend
    defaultRate: 1,
    defaultDirection: 'both',

    directionItems: function () {
        return [
            ['both', gettext('In + Out')],
            ['in', gettext('In (received by the VM)')],
            ['out', gettext('Out (sent by the VM)')],
            ['max', gettext('Larger of In and Out')],
        ];
    },

    renderDirection: function (value) {
        let item = PVE.trafficd.Utils.directionItems().find((i) => i[0] === value);
        return item ? item[1] : Ext.htmlEncode(value ?? '');
    },

    // compact form for grid columns
    renderDirectionShort: function (value) {
        let short = { both: gettext('In + Out'), in: gettext('In'), out: gettext('Out'), max: 'max(In, Out)' };
        return short[value] ?? Ext.htmlEncode(value ?? '');
    },

    defaultText: function (text) {
        return `${gettext('Default')} (${text})`;
    },

    renderRate: function (value) {
        if (value === undefined || value === null || value === '') {
            return '';
        }
        return Number(value) > 0 ? `${Ext.htmlEncode(value)} MB/s` : gettext('unlimited');
    },

    renderBytes: function (value) {
        return Ext.isNumeric(value) ? Proxmox.Utils.format_size(value) : '';
    },

    renderTime: function (value) {
        return Ext.isNumeric(value) ? Proxmox.Utils.render_timestamp(value) : '';
    },

    renderUsage: function (value, metaData, record) {
        let data = record.data;
        if (!data.configured) {
            return '';
        }
        let used = Proxmox.Utils.format_size(data.used ?? 0);
        if (!Ext.isNumeric(data.quota)) {
            return `${used} / -`;
        }
        let percent = data.quota > 0 ? (100 * data.used) / data.quota : 100;
        let res = `${used} / ${Proxmox.Utils.format_size(data.quota)} (${percent.toFixed(1)}%)`;
        if (percent >= 100) {
            res = `<span class="critical">${res}</span>`;
        } else if (percent >= 80) {
            res = `<span class="warning">${res}</span>`;
        }
        return res;
    },

    renderStatus: function (value, metaData, record) {
        let data = record.data;
        let icon, text;
        if (!data.configured) {
            return `<span style="opacity: 0.6;">${gettext('Not counted')}</span>`;
        } else if (data.removing) {
            icon = 'fa-refresh fa-spin';
            text = gettext('Removing, restoring rate');
        } else if (data.exceeded && data.limited) {
            icon = 'fa-exclamation-triangle warning';
            text = Ext.String.format(
                gettext('Limited to {0}'),
                PVE.trafficd.Utils.renderRate(data.applied ?? data['effective-rate']),
            );
        } else if (data.exceeded) {
            icon = 'fa-refresh fa-spin warning';
            text = gettext('Quota reached, applying limit');
        } else if (data.limited) {
            icon = 'fa-refresh fa-spin';
            text = gettext('Lifting limit');
        } else {
            icon = 'fa-check-circle good';
            text = Ext.isNumeric(data.quota) ? gettext('OK') : gettext('Counting, no quota');
        }
        if (data.limited) {
            let orig = Ext.isNumeric(data['orig-rate'])
                ? PVE.trafficd.Utils.renderRate(data['orig-rate'])
                : gettext('unlimited');
            metaData.tdAttr = `data-qtip="${Ext.htmlEncode(gettext('Original rate') + ': ' + orig)}"`;
        }
        return `<i class="fa fa-fw ${icon}"></i> ${text}`;
    },

    renderNic: function (value, metaData, record) {
        let res = Ext.htmlEncode(value);
        if (record.data.missing) {
            let tip = gettext('The VM has no such network device');
            res += ` <i class="fa fa-exclamation-triangle warning" data-qtip="${tip}"></i>`;
        }
        return res;
    },

    canEdit: function () {
        let caps = Ext.state.Manager.get('GuiCap');
        return !!caps.vms['VM.Config.Network'] && !!caps.dc['Sys.Modify'];
    },

    nicUrl: function (vmid, net) {
        return `/cluster/trafficd/vms/${vmid}/${net}`;
    },

    // confirm text of the reset buttons
    resetConfirm: function (rec) {
        let data = rec.data;
        return (
            Ext.String.format(
                gettext('Reset the traffic counter of VM {0} {1}?'),
                data.vmid,
                Ext.htmlEncode(data.net),
            ) +
            '<br>' +
            Ext.String.format(
                gettext('Counted since {0}: {1}'),
                PVE.trafficd.Utils.renderTime(data['last-reset']),
                Proxmox.Utils.format_size(data.used ?? 0),
            ) +
            '<br>' +
            gettext('A new counting period starts now, a rate limit is lifted.')
        );
    },

    reset: function (vmid, net, callback) {
        Proxmox.Utils.API2Request({
            url: PVE.trafficd.Utils.nicUrl(vmid, net) + '/reset',
            method: 'POST',
            success: function (response) {
                let ended = response.result.data;
                Ext.Msg.show({
                    title: gettext('Reset'),
                    icon: Ext.Msg.INFO,
                    buttons: Ext.Msg.OK,
                    message: Ext.String.format(
                        gettext('Traffic of VM {0} {1} since {2}: in {3}, out {4}, counted {5}.'),
                        vmid,
                        Ext.htmlEncode(net),
                        PVE.trafficd.Utils.renderTime(ended['last-reset']),
                        Proxmox.Utils.format_size(ended.netin),
                        Proxmox.Utils.format_size(ended.netout),
                        Proxmox.Utils.format_size(ended.used),
                    ),
                });
            },
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
            callback: callback,
        });
    },

    // proxmoxButtons only re-check enableFn on selection changes, not on store updates
    syncButtons: function (grid) {
        let rec = grid.getSelectionModel().getSelection()[0];
        for (const btn of grid.query('proxmoxButton')) {
            if (btn.selModel) {
                btn.setDisabled(!rec || btn.enableFn(rec) === false);
            }
        }
    },
};

Ext.define('pve-trafficd-nic', {
    extend: 'Ext.data.Model',
    fields: [
        'net',
        'bridge',
        'tag',
        'macaddr',
        'direction',
        'effective-direction',
        'digest',
        { name: 'configured', type: 'boolean' },
        { name: 'missing', type: 'boolean' },
        { name: 'exceeded', type: 'boolean' },
        { name: 'limited', type: 'boolean' },
        { name: 'removing', type: 'boolean' },
        { name: 'quota', type: 'number', allowNull: true },
        { name: 'used', type: 'number', allowNull: true },
        { name: 'netin', type: 'number', allowNull: true },
        { name: 'netout', type: 'number', allowNull: true },
        { name: 'last-reset', type: 'number', allowNull: true },
        { name: 'rate', type: 'number', allowNull: true },
        { name: 'effective-rate', type: 'number', allowNull: true },
        { name: 'nic-rate', type: 'number', allowNull: true },
        { name: 'orig-rate', type: 'number', allowNull: true },
        { name: 'applied', type: 'number', allowNull: true },
    ],
    idProperty: 'net',
});

Ext.define('pve-trafficd-cluster-nic', {
    extend: 'pve-trafficd-nic',
    fields: [
        { name: 'vmid', type: 'integer' },
        'node',
        { name: 'orphan', type: 'boolean' },
        { name: 'configured', type: 'boolean', defaultValue: true },
        'id',
    ],
    idProperty: 'id',
    proxy: {
        type: 'proxmox',
        url: '/api2/json/cluster/trafficd/vms',
        reader: {
            type: 'json',
            rootProperty: 'data',
            // the id must be in the raw data (calculated fields come too late), else
            // every reload creates new records and the selection is lost
            transform: (response) => {
                for (const nic of response?.data ?? []) {
                    nic.id = `${nic.vmid}/${nic.net}`;
                }
                return response;
            },
        },
    },
});

// limit rate in MB/s, empty submits a delete when deleteEmpty is set
Ext.define('PVE.trafficd.RateField', {
    extend: 'Proxmox.form.field.Integer',
    alias: 'widget.pveTrafficDRateField',

    allowDecimals: true,
    decimalPrecision: 3,
    minValue: 0.001,
    step: 0.5,
});

Ext.define('PVE.trafficd.NicInputPanel', {
    extend: 'Proxmox.panel.InputPanel',
    alias: 'widget.pveTrafficDNicInputPanel',

    // false when creating: nothing to delete then
    isEdit: true,

    // quota as loaded: [value, unit, bytes], resubmitted only when changed
    loadedQuota: undefined,

    quotaUnits: ['TiB', 'GiB', 'MiB'],

    // largest unit showing the quota exactly with up to 3 decimals, else the
    // largest unit with a value of at least 1
    quotaToField: function (bytes) {
        let units = this.quotaUnits;
        let factor = (unit) => Proxmox.Utils.SizeUnits[unit];
        let unit =
            units.find((u) => bytes >= factor(u) && Number.isInteger((bytes * 1000) / factor(u))) ??
            units.find((u) => bytes >= factor(u)) ??
            'MiB';
        return [Math.round((bytes * 1000) / factor(unit)) / 1000, unit];
    },

    onSetValues: function (values) {
        let me = this;

        if (Ext.isNumeric(values.quota)) {
            let [value, unit] = me.quotaToField(values.quota);
            me.loadedQuota = [value, unit, values.quota];
            for (const [name, v] of [['quota-value', value], ['quota-unit', unit]]) {
                let field = me.down(`field[name=${name}]`);
                field.setValue(v);
                field.resetOriginalValue();
            }
        }
        delete values.quota;
        values.direction = values.direction ?? '__default__';

        return values;
    },

    onGetValues: function (values) {
        let me = this;

        let del = [values.delete ?? []].flat().filter((key) => key !== undefined && key !== '');
        delete values.delete;

        let value = me.down('field[name=quota-value]').getValue();
        let unit = me.down('field[name=quota-unit]').getValue();
        let loaded = me.loadedQuota;
        if (value === null || value === undefined || value === '') {
            if (me.isEdit && loaded) {
                del.push('quota');
            }
        } else if (!loaded || loaded[0] !== value || loaded[1] !== unit) {
            values.quota = String(Math.round(value * Proxmox.Utils.SizeUnits[unit]));
        }

        if (del.length) {
            values.delete = del.join(',');
        }
        return values;
    },

    initComponent: function () {
        let me = this;

        let items = me.items || [];
        items.push(
            {
                xtype: 'fieldcontainer',
                fieldLabel: gettext('Quota'),
                layout: 'hbox',
                items: [
                    {
                        xtype: 'numberfield',
                        name: 'quota-value',
                        submitValue: false,
                        minValue: 0,
                        decimalPrecision: 3,
                        emptyText: gettext('none, only count'),
                        flex: 1,
                    },
                    {
                        xtype: 'proxmoxKVComboBox',
                        name: 'quota-unit',
                        submitValue: false,
                        editable: false,
                        allowBlank: false,
                        value: 'GiB',
                        comboItems: ['MiB', 'GiB', 'TiB'].map((unit) => [unit, unit]),
                        width: 80,
                        margin: '0 0 0 5',
                    },
                ],
            },
            {
                xtype: 'pveTrafficDRateField',
                name: 'rate',
                fieldLabel: gettext('Limit rate') + ' (MB/s)',
                deleteEmpty: me.isEdit,
            },
            {
                xtype: 'proxmoxKVComboBox',
                name: 'direction',
                fieldLabel: gettext('Counted traffic'),
                value: '__default__',
                comboItems: [],
                deleteEmpty: me.isEdit,
            },
            {
                xtype: 'displayfield',
                userCls: 'pmx-hint',
                value: gettext(
                    'When the counted traffic since the last reset reaches the quota, the rate of the network device in the VM hardware is set to the limit rate. A reset (or a higher quota) restores the original rate.',
                ),
            },
        );
        me.items = items;

        me.callParent();

        me.showDefaults(PVE.trafficd.Utils.defaultRate, PVE.trafficd.Utils.defaultDirection);
        Proxmox.Utils.API2Request({
            url: '/cluster/trafficd/options',
            method: 'GET',
            success: (response) => {
                let opts = response.result.data;
                me.showDefaults(
                    opts.rate ?? PVE.trafficd.Utils.defaultRate,
                    opts.direction ?? PVE.trafficd.Utils.defaultDirection,
                );
            },
            // only cosmetic: the built-in defaults stay visible without Sys.Audit
        });
    },

    // show what applies when a setting is left empty
    showDefaults: function (rate, direction) {
        let me = this;

        let rateField = me.down('field[name=rate]');
        rateField.setEmptyText(PVE.trafficd.Utils.defaultText(PVE.trafficd.Utils.renderRate(rate)));

        let directionField = me.down('field[name=direction]');
        directionField.setComboItems([
            ['__default__', PVE.trafficd.Utils.defaultText(PVE.trafficd.Utils.renderDirection(direction))],
            ...PVE.trafficd.Utils.directionItems(),
        ]);
        // refresh the displayed text of the current value
        directionField.setValue(directionField.getValue());
    },
});

// Edit the traffic accounting of one NIC. With vmid/net given the NIC is fixed,
// without, VM and NIC are selected in the dialog.
Ext.define('PVE.trafficd.NicEdit', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveTrafficDNicEdit',

    width: 520,
    method: 'PUT',

    vmid: undefined,
    net: undefined,

    initComponent: function () {
        let me = this;

        let fixed = me.vmid !== undefined && me.net !== undefined;
        let items = [];

        if (fixed) {
            me.url = `/api2/extjs${PVE.trafficd.Utils.nicUrl(me.vmid, me.net)}`;
            me.subject = `${gettext('Traffic')}: VM ${me.vmid}, ${me.net}`;
            me.autoLoad = !me.isCreate;
        } else {
            me.isCreate = true;
            me.isAdd = true;
            me.subject = gettext('Traffic');
            me.url = '/api2/extjs/cluster/trafficd/vms';
            me.submitUrl = function () {
                let vmid = me.down('field[name=vmid]').getValue();
                let net = me.down('field[name=net]').getValue();
                return `/api2/extjs${PVE.trafficd.Utils.nicUrl(vmid, net)}`;
            };

            items.push(
                {
                    xtype: 'vmComboSelector',
                    name: 'vmid',
                    fieldLabel: gettext('VM'),
                    submitValue: false,
                    allowBlank: false,
                    store: {
                        model: 'PVEResources',
                        autoLoad: true,
                        sorters: 'vmid',
                        filters: [{ property: 'type', value: 'qemu' }],
                    },
                    listeners: {
                        change: (field, vmid) => me.loadNics(vmid),
                    },
                },
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'net',
                    fieldLabel: gettext('Network Device'),
                    submitValue: false,
                    allowBlank: false,
                    disabled: true,
                    comboItems: [],
                },
            );
        }

        me.inputPanel = Ext.create('PVE.trafficd.NicInputPanel', {
            isEdit: !me.isCreate,
            items: items,
        });

        Ext.apply(me, { items: [me.inputPanel] });

        me.callParent();
    },

    // create mode: offer the NICs of the chosen VM that are not counted yet
    loadNics: function (vmid) {
        let me = this;

        let netField = me.down('field[name=net]');
        netField.setComboItems([]);
        netField.setValue(null);
        netField.setDisabled(true);
        if (!vmid) {
            return;
        }

        Proxmox.Utils.API2Request({
            url: `/cluster/trafficd/vms/${vmid}`,
            method: 'GET',
            waitMsgTarget: me,
            success: function (response) {
                let items = response.result.data
                    .filter((nic) => !nic.configured && nic.bridge)
                    .map((nic) => [nic.net, `${nic.net} (${nic.bridge}, ${nic.macaddr || '-'})`]);
                netField.setComboItems(items);
                netField.setDisabled(items.length === 0);
                netField.setEmptyText(items.length ? '' : gettext('All network devices are counted'));
                if (items.length) {
                    netField.setValue(items[0][0]);
                }
            },
            failure: (response) => Ext.Msg.alert(gettext('Error'), response.htmlStatus),
        });
    },
});

// VM -> Traffic
Ext.define('PVE.trafficd.GuestPanel', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveTrafficDGuestPanel',

    stateful: true,
    stateId: 'grid-trafficd-guest',

    initComponent: function () {
        let me = this;

        let vmid = me.pveSelNode.data.vmid;
        let baseUrl = `/cluster/trafficd/vms/${vmid}`;
        let canEdit = PVE.trafficd.Utils.canEdit();

        let store = Ext.create('Proxmox.data.UpdateStore', {
            storeid: `pve-trafficd-guest-${vmid}`,
            interval: 3000,
            model: 'pve-trafficd-nic',
            proxy: {
                type: 'proxmox',
                url: `/api2/json${baseUrl}`,
            },
        });

        let sm = Ext.create('Ext.selection.RowModel', {});

        let runEditor = function () {
            let rec = sm.getSelection()[0];
            if (!rec || !canEdit || rec.data.removing) {
                return;
            }
            Ext.create('PVE.trafficd.NicEdit', {
                vmid: vmid,
                net: rec.data.net,
                isCreate: !rec.data.configured,
                autoShow: true,
                listeners: {
                    destroy: () => store.load(),
                },
            });
        };

        let counted = (rec) => canEdit && rec.data.configured && !rec.data.removing;

        Ext.apply(me, {
            store: store,
            selModel: sm,
            tbar: [
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Edit'),
                    disabled: true,
                    selModel: sm,
                    enableFn: (rec) => canEdit && !rec.data.removing,
                    handler: runEditor,
                },
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Reset'),
                    disabled: true,
                    selModel: sm,
                    enableFn: counted,
                    confirmMsg: (rec) =>
                        PVE.trafficd.Utils.resetConfirm({ data: { ...rec.data, vmid: vmid } }),
                    handler: (btn, event, rec) =>
                        PVE.trafficd.Utils.reset(vmid, rec.data.net, () => store.load()),
                },
                {
                    xtype: 'proxmoxStdRemoveButton',
                    selModel: sm,
                    enableFn: counted,
                    getUrl: (rec) => `${baseUrl}/${rec.data.net}`,
                    customConfirmationMessage: gettext(
                        'Are you sure you want to remove the traffic accounting of {0}? Its counter is discarded.',
                    ),
                    callback: () => store.load(),
                },
            ],
            viewConfig: {
                trackOver: false,
            },
            columns: [
                {
                    header: gettext('Device'),
                    dataIndex: 'net',
                    width: 75,
                    renderer: PVE.trafficd.Utils.renderNic,
                },
                {
                    header: gettext('Bridge'),
                    dataIndex: 'bridge',
                    width: 75,
                    renderer: Ext.htmlEncode,
                },
                {
                    header: gettext('Usage'),
                    dataIndex: 'used',
                    flex: 2,
                    minWidth: 190,
                    renderer: PVE.trafficd.Utils.renderUsage,
                },
                {
                    header: gettext('In'),
                    dataIndex: 'netin',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderBytes,
                },
                {
                    header: gettext('Out'),
                    dataIndex: 'netout',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderBytes,
                },
                {
                    header: gettext('Counted'),
                    dataIndex: 'effective-direction',
                    width: 100,
                    renderer: PVE.trafficd.Utils.renderDirectionShort,
                },
                {
                    header: gettext('Limit rate'),
                    dataIndex: 'effective-rate',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderRate,
                },
                {
                    header: gettext('NIC rate'),
                    dataIndex: 'nic-rate',
                    width: 85,
                    renderer: (value, metaData, rec) =>
                        rec.data.missing ? '' : PVE.trafficd.Utils.renderRate(value ?? 0),
                },
                {
                    header: gettext('Last reset'),
                    dataIndex: 'last-reset',
                    width: 150,
                    renderer: PVE.trafficd.Utils.renderTime,
                },
                {
                    header: gettext('Status'),
                    dataIndex: 'limited',
                    flex: 2,
                    minWidth: 170,
                    cellWrap: true,
                    renderer: PVE.trafficd.Utils.renderStatus,
                },
            ],
            listeners: {
                itemdblclick: runEditor,
                destroy: () => store.stopUpdate(),
            },
        });

        me.callParent();

        me.mon(store, 'load', () => PVE.trafficd.Utils.syncButtons(me));
        Proxmox.Utils.monStoreErrors(me, store, true);
        store.startUpdate();
    },
});

// Datacenter -> Traffic: cluster wide defaults
Ext.define('PVE.trafficd.OptionsGrid', {
    extend: 'Proxmox.grid.ObjectGrid',
    alias: 'widget.pveTrafficDOptions',

    url: '/api2/json/cluster/trafficd/options',
    editorConfig: {
        url: '/api2/extjs/cluster/trafficd/options',
    },
    interval: 5000,
    cwidth1: 200,

    initComponent: function () {
        let me = this;

        let caps = Ext.state.Manager.get('GuiCap');
        let canEdit = !!caps.dc['Sys.Modify'];

        let utils = PVE.trafficd.Utils;
        let defaultRate = utils.renderRate(utils.defaultRate);
        let defaultDirection = utils.renderDirection(utils.defaultDirection);

        // no default value: an unset option is shown as such
        me.rows = {
            rate: {
                required: true,
                header: gettext('Limit rate'),
                renderer: (value) => utils.renderRate(value) || utils.defaultText(defaultRate),
                editor: canEdit
                    ? {
                          xtype: 'proxmoxWindowEdit',
                          subject: gettext('Limit rate'),
                          items: {
                              xtype: 'pveTrafficDRateField',
                              name: 'rate',
                              fieldLabel: gettext('Limit rate') + ' (MB/s)',
                              labelWidth: 120,
                              emptyText: utils.defaultText(defaultRate),
                              deleteEmpty: true,
                          },
                      }
                    : undefined,
            },
            direction: {
                required: true,
                header: gettext('Counted traffic'),
                renderer: (value) =>
                    value ? utils.renderDirection(value) : utils.defaultText(defaultDirection),
                editor: canEdit
                    ? {
                          xtype: 'proxmoxWindowEdit',
                          subject: gettext('Counted traffic'),
                          items: {
                              xtype: 'proxmoxKVComboBox',
                              name: 'direction',
                              fieldLabel: gettext('Counted traffic'),
                              labelWidth: 120,
                              value: '__default__',
                              comboItems: [
                                  ['__default__', utils.defaultText(defaultDirection)],
                                  ...utils.directionItems(),
                              ],
                              deleteEmpty: true,
                          },
                      }
                    : undefined,
            },
        };

        me.selModel = Ext.create('Ext.selection.RowModel', {});

        Ext.apply(me, {
            tbar: [
                {
                    text: gettext('Edit'),
                    xtype: 'proxmoxButton',
                    disabled: true,
                    hidden: !canEdit,
                    selModel: me.selModel,
                    handler: () => me.run_editor(),
                },
            ],
            listeners: {
                itemdblclick: me.run_editor,
            },
        });

        me.callParent();

        me.on('activate', me.rstore.startUpdate);
        me.on('destroy', me.rstore.stopUpdate);
        me.rstore.startUpdate();
    },
});

// Datacenter -> Traffic: all counted NICs
Ext.define('PVE.trafficd.ClusterNicGrid', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveTrafficDClusterNics',

    stateful: true,
    stateId: 'grid-trafficd-cluster',

    initComponent: function () {
        let me = this;

        let canEdit = PVE.trafficd.Utils.canEdit();

        let store = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-trafficd-cluster-nics',
            interval: 5000,
            model: 'pve-trafficd-cluster-nic',
            sorters: [{ property: 'vmid' }, { property: 'net' }],
        });

        let resources = PVE.data.ResourceStore;
        let guestName = (vmid) => {
            let rec = resources.findRecord('vmid', vmid, 0, false, true, true);
            return rec ? rec.data.name : '';
        };

        let sm = Ext.create('Ext.selection.RowModel', {});

        let openEditor = function (config) {
            Ext.create('PVE.trafficd.NicEdit', {
                autoShow: true,
                listeners: { destroy: () => store.load() },
                ...config,
            });
        };

        let runEditor = function () {
            let rec = sm.getSelection()[0];
            if (!rec || !canEdit || rec.data.removing) {
                return;
            }
            openEditor({ vmid: rec.data.vmid, net: rec.data.net });
        };

        let editable = (rec) => canEdit && !rec.data.removing;

        Ext.apply(me, {
            store: store,
            selModel: sm,
            tbar: [
                {
                    text: gettext('Add'),
                    disabled: !canEdit,
                    handler: () => openEditor({}),
                },
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Edit'),
                    disabled: true,
                    selModel: sm,
                    enableFn: editable,
                    handler: runEditor,
                },
                {
                    xtype: 'proxmoxButton',
                    text: gettext('Reset'),
                    disabled: true,
                    selModel: sm,
                    enableFn: editable,
                    confirmMsg: PVE.trafficd.Utils.resetConfirm,
                    handler: (btn, event, rec) =>
                        PVE.trafficd.Utils.reset(rec.data.vmid, rec.data.net, () => store.load()),
                },
                {
                    xtype: 'proxmoxStdRemoveButton',
                    selModel: sm,
                    enableFn: editable,
                    getUrl: (rec) => PVE.trafficd.Utils.nicUrl(rec.data.vmid, rec.data.net),
                    getRecordName: (rec) => `VM ${rec.data.vmid} ${rec.data.net}`,
                    customConfirmationMessage: gettext(
                        'Are you sure you want to remove the traffic accounting of {0}? Its counter is discarded.',
                    ),
                    callback: () => store.load(),
                },
            ],
            viewConfig: {
                trackOver: false,
            },
            columns: [
                {
                    header: 'VMID',
                    dataIndex: 'vmid',
                    width: 70,
                },
                {
                    header: gettext('Name'),
                    // not a model field: sorting by VMID must not mark this column
                    dataIndex: 'name',
                    flex: 1,
                    minWidth: 90,
                    sortable: false,
                    renderer: (value, meta, rec) =>
                        rec.data.orphan
                            ? `<i data-qtip="${gettext('The VM does not exist, the data is kept for a VM re-created with this VMID')}">${gettext('deleted')}</i>`
                            : Ext.htmlEncode(guestName(rec.data.vmid)),
                },
                {
                    header: gettext('Node'),
                    dataIndex: 'node',
                    width: 80,
                    renderer: Ext.htmlEncode,
                },
                {
                    header: gettext('Device'),
                    dataIndex: 'net',
                    width: 65,
                },
                {
                    header: gettext('Usage'),
                    dataIndex: 'used',
                    flex: 2,
                    minWidth: 190,
                    renderer: PVE.trafficd.Utils.renderUsage,
                },
                {
                    header: gettext('In'),
                    dataIndex: 'netin',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderBytes,
                },
                {
                    header: gettext('Out'),
                    dataIndex: 'netout',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderBytes,
                },
                {
                    header: gettext('Counted'),
                    dataIndex: 'effective-direction',
                    width: 100,
                    renderer: PVE.trafficd.Utils.renderDirectionShort,
                },
                {
                    header: gettext('Limit rate'),
                    dataIndex: 'effective-rate',
                    width: 85,
                    renderer: PVE.trafficd.Utils.renderRate,
                },
                {
                    header: gettext('Last reset'),
                    dataIndex: 'last-reset',
                    width: 150,
                    renderer: PVE.trafficd.Utils.renderTime,
                },
                {
                    header: gettext('Status'),
                    dataIndex: 'limited',
                    flex: 2,
                    minWidth: 170,
                    cellWrap: true,
                    renderer: PVE.trafficd.Utils.renderStatus,
                },
            ],
            listeners: {
                itemdblclick: runEditor,
                destroy: () => store.stopUpdate(),
            },
        });

        me.callParent();

        me.mon(store, 'load', () => PVE.trafficd.Utils.syncButtons(me));
        Proxmox.Utils.monStoreErrors(me, store, true);
        store.startUpdate();
    },
});

Ext.define('PVE.trafficd.ClusterPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveTrafficDClusterPanel',

    layout: {
        type: 'vbox',
        align: 'stretch',
    },

    items: [
        {
            xtype: 'pveTrafficDOptions',
            title: gettext('Defaults'),
            height: 130,
            border: false,
        },
        {
            xtype: 'pveTrafficDClusterNics',
            title: gettext('Counted network devices'),
            flex: 1,
            border: false,
        },
    ],
});

// add the panels to the VM and datacenter config views
Ext.define('PVE.trafficd.ConfigPanelOverride', {
    override: 'PVE.panel.Config',

    initComponent: function () {
        let me = this;

        let insertBefore = function (item, beforeId) {
            let items = me.items || [];
            let pos = items.findIndex((i) => i.itemId === beforeId);
            if (pos < 0) {
                items.push(item);
            } else {
                items.splice(pos, 0, item);
            }
            me.items = items;
        };

        try {
            let caps = Ext.state.Manager.get('GuiCap');
            if (me.$className === 'PVE.qemu.Config' && caps.vms['VM.Audit'] && !me.pveSelNode.data.template) {
                insertBefore(
                    {
                        xtype: 'pveTrafficDGuestPanel',
                        title: gettext('Traffic'),
                        iconCls: 'fa fa-exchange',
                        itemId: 'trafficd',
                    },
                    'firewall',
                );
            } else if (me.$className === 'PVE.dc.Config' && caps.dc['Sys.Audit']) {
                insertBefore(
                    {
                        xtype: 'pveTrafficDClusterPanel',
                        title: gettext('Traffic'),
                        iconCls: 'fa fa-exchange',
                        itemId: 'trafficd',
                    },
                    'firewall',
                );
            }
        } catch (err) {
            console.error('pve-trafficd: unable to add panel', err);
        }

        me.callParent(arguments);
    },
});
