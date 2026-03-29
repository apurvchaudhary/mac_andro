import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String kDefaultBaseUrl = 'http://192.168.1.49:8001';
const Duration kPollInterval = Duration(seconds: 2);
const Duration kRequestTimeout = Duration(seconds: 3);
const Duration kEventStartBuffer = Duration(minutes: 2);
const String kClockConfigsPrefKey = 'clock_configs_v1';
const String kApiBaseUrlPrefKey = 'api_base_url_v1';
const String kAvailabilitySettingsPrefKey = 'availability_settings_v1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable();
  runApp(const DashboardApp());
}

class DashboardApp extends StatelessWidget {
  const DashboardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'macgauge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Palette.background,
        colorScheme: ColorScheme.fromSeed(
          brightness: Brightness.dark,
          seedColor: Palette.cyan,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final DashboardApi _api;
  Timer? _pollTimer;

  DashboardSnapshot _snapshot = DashboardSnapshot.empty();
  DateTime _displayMonth = monthStart(DateTime.now());
  String _baseUrl = kDefaultBaseUrl;
  List<ClockConfig> _clockConfigs = const [
    ClockConfig(zoneId: 'asia_kolkata', colorId: 'blue'),
    ClockConfig(zoneId: 'europe_berlin', colorId: 'green'),
  ];
  bool _polling = false;
  int _meetingsRefreshToken = 0;

  @override
  void initState() {
    super.initState();
    _api = DashboardApi(_baseUrl);
    _loadClockConfigs();
    _loadApiSettings();
    _refreshStats();
    _pollTimer = Timer.periodic(kPollInterval, (_) => _refreshStats());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  Future<void> _refreshStats() async {
    if (_polling) {
      return;
    }

    _polling = true;
    try {
      final snapshot = await _api.fetchStats();
      if (!mounted) {
        return;
      }
      if (snapshot == _snapshot) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
      });
    } finally {
      _polling = false;
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + delta);
    });
  }

  Future<void> _openClockSettings() async {
    final updated = await showDialog<List<ClockConfig>>(
      context: context,
      builder: (context) => ClockSettingsDialog(initialConfigs: _clockConfigs),
    );

    if (!mounted || updated == null || updated.isEmpty) {
      return;
    }

    setState(() {
      _clockConfigs = updated;
    });
    unawaited(_saveClockConfigs(updated));
  }

  Future<void> _openDataSourceSettings() async {
    final updatedUrl = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => DataSourceSettingsPage(initialBaseUrl: _baseUrl),
      ),
    );

    if (!mounted || updatedUrl == null || updatedUrl == _baseUrl) {
      return;
    }

    _api.setBaseUrl(updatedUrl);
    setState(() {
      _baseUrl = updatedUrl;
    });
    unawaited(_saveApiSettings(updatedUrl));
    await _refreshStats();
  }

  Future<void> _refreshMeetingsPanel() async {
    await _refreshStats();
    if (!mounted) {
      return;
    }
    setState(() {
      _meetingsRefreshToken++;
    });
  }

  void _openCalendarPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FullScreenCalendarPage(
          api: _api,
          initialMonth: _displayMonth,
          cachedEvents: _snapshot.events,
        ),
      ),
    );
  }

  Future<void> _loadClockConfigs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawItems = prefs.getStringList(kClockConfigsPrefKey);
      final parsed = parseClockConfigs(rawItems);
      if (!mounted || parsed == null || listEquals(parsed, _clockConfigs)) {
        return;
      }
      setState(() {
        _clockConfigs = parsed;
      });
    } catch (_) {
      // Keep default clocks if local preferences are unavailable.
    }
  }

  Future<void> _saveClockConfigs(List<ClockConfig> configs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        kClockConfigsPrefKey,
        configs.map((config) => jsonEncode(config.toJson())).toList(),
      );
    } catch (_) {
      // Ignore storage failures and keep the in-memory selection.
    }
  }

  Future<void> _loadApiSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(kApiBaseUrlPrefKey);
      if (!mounted ||
          savedUrl == null ||
          !isValidBaseUrl(savedUrl) ||
          savedUrl == _baseUrl) {
        return;
      }
      _api.setBaseUrl(savedUrl);
      setState(() {
        _baseUrl = savedUrl;
      });
      unawaited(_refreshStats());
    } catch (_) {
      // Keep default URL if local preferences are unavailable.
    }
  }

  Future<void> _saveApiSettings(String baseUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kApiBaseUrlPrefKey, baseUrl);
    } catch (_) {
      // Ignore storage failures and keep the in-memory selection.
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayEvents = eventsForDay(_snapshot.events, DateTime.now())
        .take(6)
        .toList();
    final upcomingEvents = (todayEvents.isNotEmpty
            ? todayEvents
            : validatedUpcomingEvents(_snapshot.events))
        .take(6)
        .toList();

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Palette.background, Palette.backgroundRaised],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compactDashboard =
                  constraints.maxWidth < 1000 || constraints.maxHeight < 560;
              final spacing = compactDashboard ? 4.0 : 12.0;
              if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
                return const SizedBox.shrink();
              }

              return Padding(
                padding: EdgeInsets.all(compactDashboard ? 4 : spacing),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Flexible(
                      flex: compactDashboard ? 6 : 8,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: GaugeCard(
                              label: 'CPU',
                              value: _snapshot.cpu,
                              reverseColorLogic: false,
                              onHold: _openDataSourceSettings,
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: GaugeCard(
                              label: 'Memory',
                              value: _snapshot.mem,
                              reverseColorLogic: false,
                              onHold: _openDataSourceSettings,
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: GaugeCard(
                              label: 'Network',
                              value: _snapshot.net,
                              reverseColorLogic: false,
                              networkStyle: true,
                              onHold: _openDataSourceSettings,
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: GaugeCard(
                              label: 'Battery',
                              value: _snapshot.power,
                              reverseColorLogic: true,
                              onHold: _openDataSourceSettings,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    Flexible(
                      flex: compactDashboard ? 14 : 12,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ClocksCard(
                              clockConfigs: _clockConfigs,
                              onHold: _openClockSettings,
                              compactMode: compactDashboard,
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: CalendarCard(
                              displayMonth: _displayMonth,
                              onPrev: () => _shiftMonth(-1),
                              onNext: () => _shiftMonth(1),
                              onHold: _openCalendarPage,
                              compactMode: compactDashboard,
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: EventsCard(
                              events: upcomingEvents,
                              onHold: _openDataSourceSettings,
                              onRefresh: _refreshMeetingsPanel,
                              refreshToken: _meetingsRefreshToken,
                              compactMode: compactDashboard,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class GaugeCard extends StatelessWidget {
  const GaugeCard({
    super.key,
    required this.label,
    required this.value,
    required this.reverseColorLogic,
    required this.onHold,
    this.networkStyle = false,
  });

  final String label;
  final double value;
  final bool reverseColorLogic;
  final VoidCallback onHold;
  final bool networkStyle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onHold,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: RepaintBoundary(
          child: AnimatedGauge(
            label: label,
            targetValue: value.clamp(0, 100).toDouble(),
            reverseColorLogic: reverseColorLogic,
            networkStyle: networkStyle,
          ),
        ),
      ),
    );
  }
}

class AnimatedGauge extends StatelessWidget {
  const AnimatedGauge({
    super.key,
    required this.label,
    required this.targetValue,
    required this.reverseColorLogic,
    required this.networkStyle,
  });

  final String label;
  final double targetValue;
  final bool reverseColorLogic;
  final bool networkStyle;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: targetValue),
      duration: const Duration(milliseconds: 1600),
      curve: Curves.easeInOutCubic,
      builder: (context, animatedValue, child) {
        final progressColor = gaugeProgressColor(
          animatedValue,
          reverse: reverseColorLogic,
          networkStyle: networkStyle,
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < 170 || constraints.maxWidth < 260;
            final valueSize = compact ? 20.0 : 24.0;
            final percentSize = compact ? 10.0 : 11.0;
            final labelSize = compact ? 11.0 : 12.0;

            return CustomPaint(
              painter: GaugePainter(
                value: animatedValue,
                progressColor: progressColor,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: labelSize,
                            fontWeight: FontWeight.w600,
                            color: Palette.textSubtle,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const Spacer(),
                        Text.rich(
                          textAlign: TextAlign.right,
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${animatedValue.round()}',
                                style: TextStyle(
                                  fontSize: valueSize,
                                  fontWeight: FontWeight.w700,
                                  color: Palette.textPrimary,
                                  height: 1,
                                  letterSpacing: -1.2,
                                ),
                              ),
                              TextSpan(
                                text: '%',
                                style: TextStyle(
                                  fontSize: percentSize,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white.withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class ClocksCard extends StatefulWidget {
  const ClocksCard({
    super.key,
    required this.clockConfigs,
    required this.onHold,
    this.compactMode = false,
  });

  final List<ClockConfig> clockConfigs;
  final VoidCallback onHold;
  final bool compactMode;

  @override
  State<ClocksCard> createState() => _ClocksCardState();
}

class _ClocksCardState extends State<ClocksCard> {
  Timer? _timer;
  DateTime _nowUtc = DateTime.now().toUtc();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _nowUtc = DateTime.now().toUtc();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onHold,
      child: DashboardCard(
        padding: widget.compactMode
            ? const EdgeInsets.fromLTRB(6, 5, 6, 5)
            : const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final count = widget.clockConfigs.length.clamp(1, 4);
            final compact = widget.compactMode || constraints.maxHeight < 210;
            final stacked = count <= 2;
            final tallCompactStack = widget.compactMode && count == 3;
            final fullHeightCompactGrid = widget.compactMode && count == 4;

            final titleSize = widget.compactMode
                ? (tallCompactStack
                    ? 15.0
                    : (fullHeightCompactGrid ? 15.0 : (stacked ? 17.0 : 14.5)))
                : (stacked ? (compact ? 15.0 : 20.0) : (compact ? 13.0 : 16.0));
            final timeSize = widget.compactMode
                ? (tallCompactStack
                    ? 44.0
                    : (fullHeightCompactGrid
                          ? 40.0
                          : (stacked ? 60.0 : 35.0)))
                : (stacked ? (compact ? 50.0 : 76.0) : (compact ? 30.0 : 40.0));
            final gap = widget.compactMode
                ? (tallCompactStack
                      ? 2.0
                      : (fullHeightCompactGrid ? 2.0 : (stacked ? 3.0 : 2.0)))
                : (stacked ? (compact ? 4.0 : 8.0) : 4.0);

            final displays = widget.clockConfigs
                .map(
                  (config) => ClockDisplayData(
                    title: clockZoneLabel(config.zoneId),
                    color: clockColor(config.colorId),
                    time: timeLabel(clockTimeForZone(config.zoneId, _nowUtc)),
                  ),
                )
                .toList();

            final content = tallCompactStack
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (var i = 0; i < displays.length; i++) ...[
                        Expanded(
                          child: ClockBlock(
                            title: displays[i].title,
                            accentColor: displays[i].color,
                            time: displays[i].time,
                            titleSize: titleSize,
                            timeSize: timeSize,
                            gap: gap,
                            boldTime: true,
                          ),
                        ),
                        if (i != displays.length - 1) const SizedBox(height: 2),
                      ],
                    ],
                  )
                : fullHeightCompactGrid
                ? Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: ClockBlock(
                                title: displays[0].title,
                                accentColor: displays[0].color,
                                time: displays[0].time,
                                titleSize: titleSize,
                                timeSize: timeSize,
                                gap: gap,
                                boldTime: true,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: ClockBlock(
                                title: displays[1].title,
                                accentColor: displays[1].color,
                                time: displays[1].time,
                                titleSize: titleSize,
                                timeSize: timeSize,
                                gap: gap,
                                boldTime: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: ClockBlock(
                                title: displays[2].title,
                                accentColor: displays[2].color,
                                time: displays[2].time,
                                titleSize: titleSize,
                                timeSize: timeSize,
                                gap: gap,
                                boldTime: true,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: ClockBlock(
                                title: displays[3].title,
                                accentColor: displays[3].color,
                                time: displays[3].time,
                                titleSize: titleSize,
                                timeSize: timeSize,
                                gap: gap,
                                boldTime: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      for (var i = 0; i < displays.length; i++) ...[
                        Expanded(
                          child: ClockBlock(
                            title: displays[i].title,
                            accentColor: displays[i].color,
                            time: displays[i].time,
                            titleSize: titleSize,
                            timeSize: timeSize,
                            gap: gap,
                            boldTime: widget.compactMode,
                          ),
                        ),
                        if (i != displays.length - 1)
                          SizedBox(height: widget.compactMode ? 2 : (compact ? 4 : 8)),
                      ],
                    ],
                  )
                : GridView.builder(
                    itemCount: displays.length,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                          childAspectRatio: 1.5,
                        ),
                    itemBuilder: (context, index) {
                      final item = displays[index];
                      return ClockBlock(
                        title: item.title,
                        accentColor: item.color,
                        time: item.time,
                        titleSize: titleSize,
                        timeSize: timeSize,
                        gap: gap,
                        boldTime: widget.compactMode,
                      );
                    },
                  );

            return content;
          },
        ),
      ),
    );
  }
}

class ClockDisplayData {
  const ClockDisplayData({
    required this.title,
    required this.color,
    required this.time,
  });

  final String title;
  final Color color;
  final String time;
}

class ClockBlock extends StatelessWidget {
  const ClockBlock({
    super.key,
    required this.title,
    required this.accentColor,
    required this.time,
    required this.titleSize,
    required this.timeSize,
    required this.gap,
    this.boldTime = false,
  });

  final String title;
  final Color accentColor;
  final String time;
  final double titleSize;
  final double timeSize;
  final double gap;
  final bool boldTime;

  @override
  Widget build(BuildContext context) {
    final parts = time.split(':');
    final hours = parts.isNotEmpty ? parts[0] : time;
    final minutes = parts.length > 1 ? parts[1] : '';
    final seconds = parts.length > 2 ? parts[2] : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.w600,
            color: accentColor,
          ),
        ),
        SizedBox(height: gap),
        Expanded(
          child: Align(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Transform.scale(
                alignment: Alignment.center,
                scaleX: 0.94,
                scaleY: 1.12,
                child: Text.rich(
                  textAlign: TextAlign.center,
                  TextSpan(
                    style: TextStyle(
                      fontSize: timeSize,
                      fontWeight: boldTime ? FontWeight.w400 : FontWeight.w300,
                      height: 1,
                      letterSpacing: -1.2,
                    ),
                    children: [
                      TextSpan(
                        text: hours,
                        style: TextStyle(color: accentColor),
                      ),
                      const TextSpan(
                        text: ':',
                        style: TextStyle(color: Palette.textPrimary),
                      ),
                      TextSpan(
                        text: minutes,
                        style: TextStyle(color: accentColor),
                      ),
                      const TextSpan(
                        text: ':',
                        style: TextStyle(color: Palette.textPrimary),
                      ),
                      TextSpan(
                        text: seconds,
                        style: const TextStyle(color: Palette.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class ClockSettingsDialog extends StatefulWidget {
  const ClockSettingsDialog({super.key, required this.initialConfigs});

  final List<ClockConfig> initialConfigs;

  @override
  State<ClockSettingsDialog> createState() => _ClockSettingsDialogState();
}

class _ClockSettingsDialogState extends State<ClockSettingsDialog> {
  late int _count;
  late List<ClockConfig> _configs;

  @override
  void initState() {
    super.initState();
    _count = widget.initialConfigs.length.clamp(1, 4);
    _configs = List<ClockConfig>.generate(
      4,
      (index) => index < widget.initialConfigs.length
          ? widget.initialConfigs[index]
          : defaultClockConfigs[index],
    );
  }

  Widget _buildColorOption({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Colors.white.withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.12),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: ColorSwatchDot(color: color, size: 20),
      ),
    );
  }

  Widget _buildClockEditor(int index, DateTime nowUtc) {
    final config = _configs[index];
    final zoneLabel = clockZoneLabel(config.zoneId);
    final accent = clockColor(config.colorId);
    final previewTime = timeLabel(clockTimeForZone(config.zoneId, nowUtc));
    final offsetLabel = clockUtcOffsetLabel(config.zoneId, nowUtc);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Clock ${index + 1}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      zoneLabel,
                      style: TextStyle(
                        fontSize: 13,
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              previewTime,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w300,
                letterSpacing: -1.2,
                color: Palette.textPrimary,
                height: 1,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoChip(label: offsetLabel),
              _InfoChip(label: clockColorLabel(config.colorId)),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: config.zoneId,
            isExpanded: true,
            menuMaxHeight: 360,
            decoration: const InputDecoration(
              labelText: 'Time zone',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            dropdownColor: Palette.surface,
            items: clockZones
                .map(
                  (zone) => DropdownMenuItem<String>(
                    value: zone.id,
                    child: Text(zone.label),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _configs[index] = _configs[index].copyWith(zoneId: value);
              });
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Color',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: clockColors.entries
                .map(
                  (entry) => _buildColorOption(
                    color: entry.value,
                    selected: entry.key == config.colorId,
                    onTap: () {
                      setState(() {
                        _configs[index] = _configs[index].copyWith(
                          colorId: entry.key,
                        );
                      });
                    },
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nowUtc = DateTime.now().toUtc();

    return AlertDialog(
      backgroundColor: Palette.surfaceRaised,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Clock Settings'),
          const SizedBox(height: 6),
          Text(
            'Configure how many clocks appear on the dashboard, preview each zone, and pick colors directly.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.68),
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Palette.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Number of clocks',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Palette.textSubtle,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Show between 1 and 4 time zones on the dashboard.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.64),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    DropdownButton<int>(
                      value: _count,
                      dropdownColor: Palette.surface,
                      items: const [1, 2, 3, 4]
                          .map(
                            (count) => DropdownMenuItem<int>(
                              value: count,
                              child: Text('$count'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _count = value;
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              for (var index = 0; index < _count; index++) ...[
                _buildClockEditor(index, nowUtc),
                if (index != _count - 1) const SizedBox(height: 14),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(_configs.take(_count).toList());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class ColorSwatchDot extends StatelessWidget {
  const ColorSwatchDot({super.key, required this.color, this.size = 22});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final needsDarkOutline =
        color.computeLuminance() > 0.82 || color == Palette.textPrimary;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: needsDarkOutline
              ? Colors.black.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.18),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.22),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.78),
        ),
      ),
    );
  }
}

class DataSourceSettingsPage extends StatefulWidget {
  const DataSourceSettingsPage({super.key, required this.initialBaseUrl});

  final String initialBaseUrl;

  @override
  State<DataSourceSettingsPage> createState() => _DataSourceSettingsPageState();
}

class _DataSourceSettingsPageState extends State<DataSourceSettingsPage> {
  late final TextEditingController _baseUrlController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: widget.initialBaseUrl);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    super.dispose();
  }

  void _save() {
    final sanitized = sanitizeBaseUrl(_baseUrlController.text);
    if (!isValidBaseUrl(sanitized)) {
      setState(() {
        _errorText = 'Enter a valid http:// or https:// URL';
      });
      return;
    }

    Navigator.of(context).pop(sanitized);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Scaffold(
      backgroundColor: Palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Data Source Settings'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                20 + viewInsets.bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DashboardCard(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Base URL',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Palette.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Used for gauges, meetings, and calendar day details. The app reads /stats and /events from this address.',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.72),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _baseUrlController,
                            keyboardType: TextInputType.url,
                            autofocus: true,
                            decoration: InputDecoration(
                              labelText: 'Server URL',
                              hintText: 'http://192.168.1.49:8001',
                              errorText: _errorText,
                              border: const OutlineInputBorder(),
                            ),
                            onChanged: (_) {
                              setState(() {
                                _errorText = null;
                              });
                            },
                            onSubmitted: (_) => _save(),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Example endpoint: ${sanitizeBaseUrl(_baseUrlController.text.isEmpty ? widget.initialBaseUrl : _baseUrlController.text)}/stats',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              OutlinedButton(
                                onPressed: () {
                                  _baseUrlController.text = kDefaultBaseUrl;
                                  setState(() {
                                    _errorText = null;
                                  });
                                },
                                child: const Text('Reset Default'),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Cancel'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _save,
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class AvailabilitySettingsDialog extends StatefulWidget {
  const AvailabilitySettingsDialog({super.key, required this.initialSettings});

  final AvailabilitySettings initialSettings;

  @override
  State<AvailabilitySettingsDialog> createState() =>
      _AvailabilitySettingsDialogState();
}

class _AvailabilitySettingsDialogState
    extends State<AvailabilitySettingsDialog> {
  late bool _enabled;
  late int _workStartMinute;
  late int _workEndMinute;
  late int _minimumSlotMinutes;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialSettings.enabled;
    _workStartMinute = widget.initialSettings.workStartMinute;
    _workEndMinute = widget.initialSettings.workEndMinute;
    _minimumSlotMinutes = widget.initialSettings.minimumSlotMinutes;
  }

  void _save() {
    if (_workEndMinute <= _workStartMinute) {
      return;
    }
    Navigator.of(context).pop(
      AvailabilitySettings(
        enabled: _enabled,
        workStartMinute: _workStartMinute,
        workEndMinute: _workEndMinute,
        minimumSlotMinutes: _minimumSlotMinutes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Palette.surfaceRaised,
      title: const Text('Free Slot Settings'),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enable free slots'),
                  subtitle: Text(
                    'Show suggested open time blocks for this day',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.62),
                    ),
                  ),
                  value: _enabled,
                  onChanged: (value) {
                    setState(() {
                      _enabled = value;
                    });
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  initialValue: _workStartMinute,
                  decoration: const InputDecoration(
                    labelText: 'Work day start',
                    border: OutlineInputBorder(),
                  ),
                  isExpanded: true,
                  menuMaxHeight: 320,
                  disabledHint: Text(minuteLabel(_workStartMinute)),
                  dropdownColor: Palette.surface,
                  items: workMinuteOptions
                      .map(
                        (minute) => DropdownMenuItem<int>(
                          value: minute,
                          child: Text(minuteLabel(minute)),
                        ),
                      )
                      .toList(),
                  onChanged: !_enabled
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _workStartMinute = value;
                            if (_workEndMinute <= _workStartMinute) {
                              _workEndMinute = math.min(
                                24 * 60,
                                _workStartMinute + 60,
                              );
                            }
                          });
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _workEndMinute,
                  decoration: const InputDecoration(
                    labelText: 'Work day end',
                    border: OutlineInputBorder(),
                  ),
                  isExpanded: true,
                  menuMaxHeight: 320,
                  disabledHint: Text(minuteLabel(_workEndMinute)),
                  dropdownColor: Palette.surface,
                  items: workMinuteOptions
                      .where((minute) => minute > _workStartMinute)
                      .map(
                        (minute) => DropdownMenuItem<int>(
                          value: minute,
                          child: Text(minuteLabel(minute)),
                        ),
                      )
                      .toList(),
                  onChanged: !_enabled
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _workEndMinute = value;
                          });
                        },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _minimumSlotMinutes,
                  decoration: const InputDecoration(
                    labelText: 'Minimum free slot',
                    border: OutlineInputBorder(),
                  ),
                  isExpanded: true,
                  menuMaxHeight: 320,
                  disabledHint: Text(durationLabel(_minimumSlotMinutes)),
                  dropdownColor: Palette.surface,
                  items: const [15, 30, 45, 60, 90, 120]
                      .map(
                        (minutes) => DropdownMenuItem<int>(
                          value: minutes,
                          child: Text(durationLabel(minutes)),
                        ),
                      )
                      .toList(),
                  onChanged: !_enabled
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _minimumSlotMinutes = value;
                          });
                        },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class FreeSlotsPanel extends StatelessWidget {
  const FreeSlotsPanel({
    super.key,
    required this.settings,
    required this.slots,
    required this.onClose,
  });

  final AvailabilitySettings settings;
  final List<FreeSlot> slots;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Palette.surfaceRaised, Palette.surface],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Free Slots',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Palette.textPrimary,
                    ),
                  ),
                ),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${minuteLabel(settings.workStartMinute)} - ${minuteLabel(settings.workEndMinute)} · ${durationLabel(settings.minimumSlotMinutes)} min',
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withValues(alpha: 0.68),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: slots.isEmpty
                  ? Center(
                      child: Text(
                        'No free slots in this work window',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: slots.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final slot = slots[index];
                        return SizedBox(
                          width: 138,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              color: Colors.white.withValues(alpha: 0.05),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${minuteLabel(slot.startMinute)} - ${minuteLabel(slot.endMinute)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Palette.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    durationLabel(slot.durationMinutes),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white.withValues(
                                        alpha: 0.7,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class CalendarCard extends StatelessWidget {
  const CalendarCard({
    super.key,
    required this.displayMonth,
    required this.onPrev,
    required this.onNext,
    required this.onHold,
    this.compactMode = false,
  });

  final DateTime displayMonth;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onHold;
  final bool compactMode;

  @override
  Widget build(BuildContext context) {
    final rows = monthRows(displayMonth);

    return GestureDetector(
      onTap: onHold,
      child: DashboardCard(
        padding: compactMode
            ? const EdgeInsets.fromLTRB(6, 5, 6, 5)
            : const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = compactMode || constraints.maxHeight < 210;
            final monthSize = compactMode ? 22.0 : (compact ? 19.0 : 25.0);
            final weekSize = compactMode ? 13.5 : (compact ? 12.0 : 14.0);
            final daySize = compactMode ? 20.0 : (compact ? 17.0 : 19.0);
            final sectionGap = compactMode ? 2.0 : (compact ? 6.0 : 10.0);
            final cellSize = compactMode ? 40.0 : (compact ? 34.0 : 40.0);
            final iconPadding = compact ? EdgeInsets.zero : null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Center(
                      child: Text(
                        monthYearLabel(displayMonth),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: monthSize,
                          fontWeight: FontWeight.w700,
                          color: Palette.textPrimary,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: onPrev,
                            icon: const Icon(Icons.chevron_left_rounded),
                            color: Palette.textPrimary,
                            visualDensity: VisualDensity.compact,
                            padding: iconPadding,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                          ),
                          IconButton(
                            onPressed: onNext,
                            icon: const Icon(Icons.chevron_right_rounded),
                            color: Palette.textPrimary,
                            visualDensity: VisualDensity.compact,
                            padding: iconPadding,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: sectionGap),
                Expanded(
                  child: Column(
                    children: [
                      WeekdayHeader(fontSize: weekSize),
                      SizedBox(height: compactMode ? 4 : (compact ? 2 : 6)),
                      Expanded(
                        child: Column(
                          children: [
                            for (final row in rows)
                              Expanded(
                                child: Row(
                                  children: [
                                    for (final day in row)
                                      Expanded(
                                        child: Center(
                                          child: CalendarDayCell(
                                            day: day,
                                            isToday:
                                                day != null &&
                                                isSameDay(
                                                  DateTime(
                                                    displayMonth.year,
                                                    displayMonth.month,
                                                    day,
                                                  ),
                                                  DateTime.now(),
                                                ),
                                            fontSize: daySize,
                                            cellSize: cellSize,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class WeekdayHeader extends StatelessWidget {
  const WeekdayHeader({super.key, required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final label in weekdayLabels)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  color: Palette.calendarWeekday,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    super.key,
    required this.day,
    required this.isToday,
    required this.fontSize,
    required this.cellSize,
    this.onTap,
  });

  final int? day;
  final bool isToday;
  final double fontSize;
  final double cellSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (day == null) {
      return const SizedBox.shrink();
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isToday ? Palette.today.withValues(alpha: 0.18) : null,
          ),
          child: SizedBox(
            width: cellSize,
            height: cellSize,
            child: Center(
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                  color: isToday ? Palette.today : Palette.calendarDay,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FullScreenCalendarPage extends StatefulWidget {
  const FullScreenCalendarPage({
    super.key,
    required this.api,
    required this.initialMonth,
    required this.cachedEvents,
  });

  final DashboardApi api;
  final DateTime initialMonth;
  final List<CalendarEvent> cachedEvents;

  @override
  State<FullScreenCalendarPage> createState() => _FullScreenCalendarPageState();
}

class _FullScreenCalendarPageState extends State<FullScreenCalendarPage> {
  late DateTime _displayMonth;

  @override
  void initState() {
    super.initState();
    _displayMonth = monthStart(widget.initialMonth);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + delta);
    });
  }

  void _openDaySchedule(DateTime dayDate) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => DaySchedulePage(
          api: widget.api,
          dayDate: dayDate,
          fallbackEvents: widget.cachedEvents,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = monthRows(_displayMonth);

    return Scaffold(
      backgroundColor: Palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(monthYearLabel(_displayMonth)),
        actions: [
          IconButton(
            onPressed: () => _shiftMonth(-1),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          IconButton(
            onPressed: () => _shiftMonth(1),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: DashboardCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                const WeekdayHeader(fontSize: 16),
                const SizedBox(height: 14),
                Expanded(
                  child: Column(
                    children: [
                      for (final row in rows)
                        Expanded(
                          child: Row(
                            children: [
                              for (final day in row)
                                Expanded(
                                  child: Center(
                                    child: CalendarDayCell(
                                      day: day,
                                      isToday:
                                          day != null &&
                                          isSameDay(
                                            DateTime(
                                              _displayMonth.year,
                                              _displayMonth.month,
                                              day,
                                            ),
                                            DateTime.now(),
                                          ),
                                      fontSize: 24,
                                      cellSize: 58,
                                      onTap: day == null
                                          ? null
                                          : () => _openDaySchedule(
                                              DateTime(
                                                _displayMonth.year,
                                                _displayMonth.month,
                                                day,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DaySchedulePage extends StatefulWidget {
  const DaySchedulePage({
    super.key,
    required this.api,
    required this.dayDate,
    required this.fallbackEvents,
  });

  final DashboardApi api;
  final DateTime dayDate;
  final List<CalendarEvent> fallbackEvents;

  @override
  State<DaySchedulePage> createState() => _DaySchedulePageState();
}

class _DaySchedulePageState extends State<DaySchedulePage> {
  bool _loading = true;
  bool _showFreeSlots = AvailabilitySettings.defaults.enabled;
  List<CalendarEvent> _events = const [];
  AvailabilitySettings _availabilitySettings = AvailabilitySettings.defaults;

  @override
  void initState() {
    super.initState();
    _loadAvailabilitySettings();
    _loadEvents();
  }

  Future<void> _loadAvailabilitySettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kAvailabilitySettingsPrefKey);
      if (raw == null) {
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final parsed = AvailabilitySettings.fromJson(decoded);
      if (!mounted || parsed == null) {
        return;
      }
      setState(() {
        _availabilitySettings = parsed;
        _showFreeSlots = parsed.enabled;
      });
    } catch (_) {
      // Keep defaults if persisted settings are unavailable.
    }
  }

  Future<void> _saveAvailabilitySettings(AvailabilitySettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kAvailabilitySettingsPrefKey,
        jsonEncode(settings.toJson()),
      );
    } catch (_) {
      // Keep in-memory settings even if persistence fails.
    }
  }

  Future<void> _openAvailabilitySettings() async {
    final updated = await showDialog<AvailabilitySettings>(
      context: context,
      builder: (context) =>
          AvailabilitySettingsDialog(initialSettings: _availabilitySettings),
    );

    if (!mounted || updated == null) {
      return;
    }

    setState(() {
      _availabilitySettings = updated;
      _showFreeSlots = updated.enabled;
    });
    unawaited(_saveAvailabilitySettings(updated));
  }

  Future<void> _loadEvents() async {
    final events = await widget.api.fetchEventsForDate(
      widget.dayDate,
      fallbackEvents: widget.fallbackEvents,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _events = events;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(dayDateLabel(widget.dayDate)),
        actions: [
          if (_availabilitySettings.enabled && !_showFreeSlots)
            IconButton(
              onPressed: () {
                setState(() {
                  _showFreeSlots = true;
                });
              },
              icon: const Icon(Icons.view_sidebar_rounded),
              tooltip: 'Show free slots',
            ),
          IconButton(
            onPressed: _openAvailabilitySettings,
            icon: const Icon(Icons.tune_rounded),
            tooltip: 'Availability settings',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DashboardCard(
            padding: const EdgeInsets.all(16),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _events.isEmpty
                ? Center(
                    child: Text(
                      'No meetings for this day',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final freeSlots = freeSlotsForDay(
                        _events,
                        widget.dayDate,
                        _availabilitySettings,
                      );
                      final wide = constraints.maxWidth >= 1080;

                      final timeline = DayTimeline(
                        events: _events,
                        dayDate: widget.dayDate,
                      );
                      final slotsPanel = FreeSlotsPanel(
                        settings: _availabilitySettings,
                        slots: freeSlots,
                        onClose: () {
                          setState(() {
                            _showFreeSlots = false;
                          });
                        },
                      );

                      if (!_availabilitySettings.enabled || !_showFreeSlots) {
                        return timeline;
                      }

                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: timeline),
                            const SizedBox(width: 16),
                            SizedBox(width: 240, child: slotsPanel),
                          ],
                        );
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 142, child: slotsPanel),
                          const SizedBox(height: 14),
                          Expanded(child: timeline),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class DayTimeline extends StatefulWidget {
  const DayTimeline({super.key, required this.events, required this.dayDate});

  final List<CalendarEvent> events;
  final DateTime dayDate;

  @override
  State<DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<DayTimeline> {
  final ScrollController _scrollController = ScrollController();
  String? _lastAutoScrollKey;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScrollToFirstMeeting({
    required List<TimelineEntry> items,
    required double viewportHeight,
    required double contentHeight,
    required double pixelsPerMinute,
  }) {
    if (items.isEmpty || !_scrollController.hasClients) {
      return;
    }

    final key =
        '${widget.dayDate.toIso8601String()}-${items.first.startMinute}-${items.length}';
    if (_lastAutoScrollKey == key) {
      return;
    }
    _lastAutoScrollKey = key;

    final maxScroll = math.max(0.0, contentHeight - viewportHeight);
    final target = math.max(
      0.0,
      (items.first.startMinute * pixelsPerMinute) - 24,
    );
    _scrollController.jumpTo(target.clamp(0.0, maxScroll));
  }

  @override
  Widget build(BuildContext context) {
    const double pixelsPerMinute = 2.0;
    const double leftPad = 64;
    const double rightPad = 14;
    final items = timelineItemsForDay(widget.events, widget.dayDate);
    final contentHeight = 24 * 60 * pixelsPerMinute;

    return LayoutBuilder(
      builder: (context, constraints) {
        final timelineWidth = constraints.maxWidth - leftPad - rightPad;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _autoScrollToFirstMeeting(
            items: items,
            viewportHeight: constraints.maxHeight,
            contentHeight: contentHeight,
            pixelsPerMinute: pixelsPerMinute,
          );
        });

        return RepaintBoundary(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: SizedBox(
              height: contentHeight,
              child: Stack(
                children: [
                for (var hour = 0; hour <= 24; hour++)
                  Positioned(
                    left: leftPad,
                    right: rightPad,
                    top: hour * 60 * pixelsPerMinute,
                    child: Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                for (var halfHour = 0; halfHour < 24; halfHour++)
                  Positioned(
                    left: leftPad,
                    right: rightPad,
                    top: ((halfHour * 60) + 30) * pixelsPerMinute,
                    child: SizedBox(
                      height: 1,
                      child: CustomPaint(
                        painter: DashedLinePainter(
                          color: Colors.white.withValues(alpha: 0.08),
                          dashWidth: 5,
                          dashGap: 5,
                        ),
                      ),
                    ),
                  ),
                for (var hour = 0; hour < 24; hour++)
                  Positioned(
                    left: 0,
                    width: leftPad - 14,
                    top: (hour * 60 * pixelsPerMinute) - 9,
                    child: Text(
                      '${hour.toString().padLeft(2, '0')}:00',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Palette.textSubtle,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                for (var halfHour = 0; halfHour < 24; halfHour++)
                  Positioned(
                    left: 0,
                    width: leftPad - 14,
                    top: ((halfHour * 60) + 30) * pixelsPerMinute - 8,
                    child: Text(
                      '${halfHour.toString().padLeft(2, '0')}:30',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Palette.textSubtle,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                for (final item in items)
                  Positioned(
                    left:
                        leftPad +
                        ((timelineWidth / item.totalColumns) *
                            item.columnIndex) +
                        8,
                    top: item.startMinute * pixelsPerMinute + 4,
                    width: (timelineWidth / item.totalColumns) - 16,
                    height: math.max(
                      18,
                      (item.endMinute - item.startMinute) * pixelsPerMinute - 8,
                    ),
                    child: _TimelineEventCard(event: item.event),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimelineEventCard extends StatelessWidget {
  const _TimelineEventCard({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final accent = timelineAccentColor(event);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: Color.lerp(Palette.surfaceRaised, accent, 0.18)?.withValues(
              alpha: 0.9,
            ) ??
            Palette.surfaceRaised,
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ultraTiny = constraints.maxHeight < 20;
            final micro = constraints.maxHeight < 30;
            final tiny = constraints.maxHeight < 38;
            final short = constraints.maxHeight < 52;
            final compact = constraints.maxHeight < 44;

            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: accent, width: 3)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: ultraTiny
                      ? 4
                      : (micro ? 4 : (short ? 4.5 : 6)),
                  vertical: ultraTiny ? 0 : (micro ? 0 : (short ? 0.5 : 1)),
                ),
                child: DefaultTextStyle(
                  style: const TextStyle(color: Colors.white),
                  child: ultraTiny
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            event.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              height: 1,
                            ),
                          ),
                        )
                      : micro
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                event.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    timelineTimeRangeLabel(event),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: accent.withValues(alpha: 0.95),
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : tiny
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                event.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    timelineTimeRangeLabel(event),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: accent.withValues(alpha: 0.95),
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  event.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: short ? 18 : 21,
                                    fontWeight: FontWeight.w900,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: compact ? 3 : 6),
                            Flexible(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    timelineTimeRangeLabel(event),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: short ? 15 : 17.5,
                                      fontWeight: FontWeight.w700,
                                      color: accent.withValues(alpha: 0.95),
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class DashedLinePainter extends CustomPainter {
  const DashedLinePainter({
    required this.color,
    required this.dashWidth,
    required this.dashGap,
  });

  final Color color;
  final double dashWidth;
  final double dashGap;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double startX = 0;
    while (startX < size.width) {
      final endX = math.min(startX + dashWidth, size.width);
      canvas.drawLine(Offset(startX, 0.5), Offset(endX, 0.5), paint);
      startX += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant DashedLinePainter oldDelegate) {
    return color != oldDelegate.color ||
        dashWidth != oldDelegate.dashWidth ||
        dashGap != oldDelegate.dashGap;
  }
}

class EventsCard extends StatelessWidget {
  const EventsCard({
    super.key,
    required this.events,
    required this.onHold,
    required this.onRefresh,
    required this.refreshToken,
    this.compactMode = false,
  });

  final List<CalendarEvent> events;
  final VoidCallback onHold;
  final Future<void> Function() onRefresh;
  final int refreshToken;
  final bool compactMode;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onHold,
      child: DashboardCard(
        padding: compactMode
            ? const EdgeInsets.fromLTRB(4, 4, 4, 3)
            : const EdgeInsets.fromLTRB(10, 10, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Text(
                    'Meetings',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compactMode ? 19 : 18,
                      fontWeight: FontWeight.w700,
                      color: Palette.textSubtle,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: () async {
                      await onRefresh();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    iconSize: compactMode ? 17 : 18,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    color: Palette.textSubtle,
                    tooltip: 'Refresh meetings',
                  ),
                ),
              ],
            ),
            SizedBox(height: compactMode ? 2 : 8),
            Expanded(
              child: events.isEmpty
                  ? Center(
                      child: Text(
                        'No upcoming meetings',
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                    )
                  : MiniMeetingsTimeline(
                      events: events,
                      refreshToken: refreshToken,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class MiniMeetingsTimeline extends StatefulWidget {
  const MiniMeetingsTimeline({
    super.key,
    required this.events,
    required this.refreshToken,
  });

  final List<CalendarEvent> events;
  final int refreshToken;

  @override
  State<MiniMeetingsTimeline> createState() => _MiniMeetingsTimelineState();
}

class _MiniMeetingsTimelineState extends State<MiniMeetingsTimeline> {
  final ScrollController _scrollController = ScrollController();
  String? _lastAutoScrollKey;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoCenterMinute({
    required int focusMinute,
    required int rangeStart,
    required double pixelsPerMinute,
    required double viewportHeight,
    required double contentHeight,
    required String key,
  }) {
    if (!_scrollController.hasClients || _lastAutoScrollKey == key) {
      return;
    }

    _lastAutoScrollKey = key;
    final maxScroll = math.max(0.0, contentHeight - viewportHeight);
    final topAnchor = math.max(20.0, viewportHeight * 0.18);
    final target = (((focusMinute - rangeStart) * pixelsPerMinute) -
            topAnchor)
        .clamp(0.0, maxScroll);
    final distance = (_scrollController.offset - target).abs();
    final durationMs = distance < 32
        ? 140
        : distance < 180
        ? 260
        : 420;
    unawaited(
      _scrollController.animateTo(
        target,
        duration: Duration(milliseconds: durationMs),
        curve: Curves.easeInOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seed = widget.events.first.start?.toLocal() ?? DateTime.now();
    final dayDate = DateTime(seed.year, seed.month, seed.day);
    final dayEvents = eventsForDay(widget.events, dayDate);
    final items = timelineItemsForDay(dayEvents, dayDate);
    final now = DateTime.now();
    final currentMinute = (now.hour * 60) + now.minute;

    if (items.isEmpty) {
      return Center(
        child: Text(
          'No meetings for this day',
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.65),
          ),
        ),
      );
    }

    final hasMeetingAfterNow =
        !isSameDay(dayDate, now) ||
        items.any((item) => item.endMinute > currentMinute);
    if (!hasMeetingAfterNow) {
      return Center(
        child: Text(
          'No meetings',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    final firstStart = items
        .map((item) => item.startMinute)
        .reduce(math.min);
    final lastEnd = items.map((item) => item.endMinute).reduce(math.max);
    final rangeStart = math.max(0, ((firstStart - 5) ~/ 30) * 30);
    final rangeEnd = math.min(
      24 * 60,
      (((lastEnd + 5) + 29) ~/ 30) * 30,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        const leftPad = 24.0;
        const rightPad = 1.0;
        const horizontalGap = 4.0;
        final showCurrentTimeLine =
            isSameDay(dayDate, now) &&
            currentMinute >= rangeStart &&
            currentMinute <= rangeEnd;
        final timelineWidth = constraints.maxWidth - leftPad - rightPad;
        final totalMinutes = math.max(60, rangeEnd - rangeStart);
        final pixelsPerMinute = math.max(
          1.55,
          (constraints.maxHeight - 2) / totalMinutes,
        );
        final contentHeight = totalMinutes * pixelsPerMinute;
        final focusMinute = showCurrentTimeLine ? currentMinute : firstStart;
        final scrollKey =
            '${widget.refreshToken}-${dayDate.toIso8601String()}-$rangeStart-$rangeEnd-$focusMinute';

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          _autoCenterMinute(
            focusMinute: focusMinute,
            rangeStart: rangeStart,
            pixelsPerMinute: pixelsPerMinute,
            viewportHeight: constraints.maxHeight,
            contentHeight: contentHeight,
            key: scrollKey,
          );
        });

        return RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SingleChildScrollView(
              controller: _scrollController,
              child: SizedBox(
                height: contentHeight,
                child: Stack(
                  children: [
                  for (
                    var minute = rangeStart;
                    minute <= rangeEnd;
                    minute += 30
                  )
                    Positioned(
                      left: leftPad,
                      right: rightPad,
                      top: (minute - rangeStart) * pixelsPerMinute,
                      child: SizedBox(
                        height: 1,
                        child: minute % 60 == 0
                            ? DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              )
                            : CustomPaint(
                                painter: DashedLinePainter(
                                  color: Colors.white.withValues(alpha: 0.06),
                                  dashWidth: 4,
                                  dashGap: 4,
                                ),
                              ),
                      ),
                    ),
                  for (
                    var minute = rangeStart;
                    minute < rangeEnd;
                    minute += 30
                  )
                    if (minute % 60 == 0)
                      Positioned(
                        left: 0,
                        width: leftPad - 2,
                        top: ((minute - rangeStart) * pixelsPerMinute) - 7,
                        child: Text(
                          compactHourLabel(minute),
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Palette.textSubtle,
                          ),
                        ),
                      ),
                  for (final item in items)
                    Positioned(
                      left:
                          leftPad +
                          ((timelineWidth / item.totalColumns) * item.columnIndex) +
                          (horizontalGap / 2),
                      top:
                          ((item.startMinute - rangeStart) * pixelsPerMinute) +
                          2,
                      width:
                          (timelineWidth / item.totalColumns) - horizontalGap,
                      height: math.max(
                        26,
                        ((item.endMinute - item.startMinute) * pixelsPerMinute) -
                            4,
                      ),
                      child: _TimelineEventCard(event: item.event),
                    ),
                  if (showCurrentTimeLine)
                    Positioned(
                      left: 7,
                      right: rightPad,
                      top: (currentMinute - rangeStart) * pixelsPerMinute,
                      child: SizedBox(
                        height: 1,
                        child: CustomPaint(
                          painter: DashedLinePainter(
                            color: Palette.highlight.withValues(alpha: 0.95),
                            dashWidth: 6,
                            dashGap: 4,
                          ),
                        ),
                      ),
                    ),
                  if (showCurrentTimeLine)
                    Positioned(
                      left: 4,
                      top: ((currentMinute - rangeStart) * pixelsPerMinute) - 3,
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Palette.highlight,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.showBorder = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Palette.surfaceRaised, Palette.surface],
          ),
          border: showBorder
              ? Border.all(color: Colors.white.withValues(alpha: 0.08))
              : null,
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 20,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class GaugePainter extends CustomPainter {
  const GaugePainter({required this.value, required this.progressColor});

  final double value;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    final bezelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
      const Radius.circular(12),
    );
    final dialRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(8, 8, size.width - 16, size.height - 16),
      const Radius.circular(8),
    );

    final framePaint = Paint()
      ..isAntiAlias = true
      ..color = Palette.surfaceRaised;
    final frameInnerPaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFF0D131D);
    final frameStrokePaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.08);
    final dialStrokePaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withValues(alpha: 0.05);
    final dialPaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFF070B12);

    canvas.save();
    canvas.clipRRect(bezelRect);
    canvas.drawRRect(bezelRect, framePaint);
    canvas.drawRRect(bezelRect, frameStrokePaint);
    canvas.drawRRect(dialRect, frameInnerPaint);
    canvas.drawRRect(dialRect.deflate(2), dialPaint);
    canvas.drawRRect(dialRect.deflate(2), dialStrokePaint);

    final center = Offset(size.width / 2, size.height * 0.86);
    final radius = math.min(size.width * 0.42, size.height * 0.62);
    final arcRect = Rect.fromCircle(center: center, radius: radius);
    final startAngle = degreesToRadians(205);
    final sweepAngle = degreesToRadians(130);
    final progressSweep = sweepAngle * (value / 100);

    final trackPaint = Paint()
      ..isAntiAlias = true
      ..color = Palette.gaugeTrack.withValues(alpha: 0.95)
      ..strokeWidth = 11
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final progressGlowPaint = Paint()
      ..isAntiAlias = true
      ..color = progressColor.withValues(alpha: 0.14)
      ..strokeWidth = 14
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final progressPaint = Paint()
      ..isAntiAlias = true
      ..color = progressColor
      ..strokeWidth = 12
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final tickPaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFFE2F0FA).withValues(alpha: 0.88)
      ..strokeWidth = 1.2;
    final minorTickPaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFFCFE1EE).withValues(alpha: 0.62)
      ..strokeWidth = 0.9;

    canvas.drawArc(arcRect, startAngle, sweepAngle, false, trackPaint);
    if (value > 0) {
      canvas.drawArc(
        arcRect,
        startAngle,
        progressSweep,
        false,
        progressGlowPaint,
      );
      canvas.drawArc(arcRect, startAngle, progressSweep, false, progressPaint);
    }

    for (var i = 0; i <= 25; i++) {
      final t = i / 25;
      final angle = startAngle + (sweepAngle * t);
      final outer = radius + 2;
      final major = i % 5 == 0;
      final inner = outer - (major ? 18 : 10);
      final p1 = Offset(
        center.dx + outer * math.cos(angle),
        center.dy + outer * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + inner * math.cos(angle),
        center.dy + inner * math.sin(angle),
      );
      canvas.drawLine(p1, p2, major ? tickPaint : minorTickPaint);
    }

    for (var i = 0; i <= 5; i++) {
      final t = i / 5;
      final angle = startAngle + (sweepAngle * t);
      final labelRadius = radius - 22;
      final offset = Offset(
        center.dx + labelRadius * math.cos(angle),
        center.dy + labelRadius * math.sin(angle),
      );
      final painter = kGaugeNumberPainters[i];
      painter.paint(
        canvas,
        Offset(
          offset.dx - (painter.width / 2),
          offset.dy - (painter.height / 2),
        ),
      );
    }

    final needleAngle = startAngle + (sweepAngle * (value / 100));
    final needleBase = Offset(
      center.dx - 8 * math.cos(needleAngle),
      center.dy - 8 * math.sin(needleAngle),
    );
    final needleTip = Offset(
      center.dx + (radius - 18) * math.cos(needleAngle),
      center.dy + (radius - 18) * math.sin(needleAngle),
    );
    final needleShadowPaint = Paint()
      ..isAntiAlias = true
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    final needlePaint = Paint()
      ..isAntiAlias = true
      ..color = const Color(0xFFFF4D4D)
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      needleBase.translate(1.5, 2),
      needleTip.translate(1.5, 2),
      needleShadowPaint,
    );
    canvas.drawLine(needleBase, needleTip, needlePaint);

    final pointerPath = Path()
      ..moveTo(needleTip.dx, needleTip.dy)
      ..lineTo(
        needleTip.dx - 11 * math.cos(needleAngle) - 4.5 * math.sin(needleAngle),
        needleTip.dy - 11 * math.sin(needleAngle) + 4.5 * math.cos(needleAngle),
      )
      ..lineTo(
        needleTip.dx - 11 * math.cos(needleAngle) + 4.5 * math.sin(needleAngle),
        needleTip.dy - 11 * math.sin(needleAngle) - 4.5 * math.cos(needleAngle),
      )
      ..close();
    canvas.drawPath(pointerPath, needlePaint);

    canvas.drawCircle(
      center.translate(0, 2),
      8.5,
      Paint()..color = Colors.black.withValues(alpha: 0.32),
    );
    canvas.drawCircle(
      center,
      8.5,
      Paint()..color = const Color(0xFFA8B5C3),
    );
    canvas.drawCircle(center, 3, Paint()..color = const Color(0xFFF7FAFD));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant GaugePainter oldDelegate) {
    return value != oldDelegate.value ||
        progressColor != oldDelegate.progressColor;
  }
}

class DashboardApi {
  DashboardApi(String baseUrl)
    : _baseUri = Uri.parse(baseUrl),
      _client = HttpClient()..connectionTimeout = kRequestTimeout;

  Uri _baseUri;
  final HttpClient _client;

  void setBaseUrl(String baseUrl) {
    _baseUri = Uri.parse(baseUrl);
  }

  Future<DashboardSnapshot> fetchStats() async {
    try {
      final json = await _getJson(_baseUri.replace(path: '/stats'));
      if (json is! Map<String, dynamic>) {
        return DashboardSnapshot.empty();
      }
      return DashboardSnapshot.fromJson(json);
    } catch (_) {
      return DashboardSnapshot.empty();
    }
  }

  Future<List<CalendarEvent>> fetchEventsForDate(
    DateTime dayDate, {
    List<CalendarEvent> fallbackEvents = const [],
  }) async {
    try {
      final json = await _getJson(
        _baseUri.replace(
          path: '/events',
          queryParameters: {'date': apiDateLabel(dayDate)},
        ),
      );
      final events = parseCalendarEvents(json);
      if (events.isNotEmpty) {
        return eventsForDay(events, dayDate);
      }
    } catch (_) {
      // Fall back to already-loaded events below.
    }
    return eventsForDay(fallbackEvents, dayDate);
  }

  Future<dynamic> _getJson(Uri uri) async {
    final request = await _client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(kRequestTimeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Bad status ${response.statusCode}', uri: uri);
    }
    return jsonDecode(body);
  }

  void dispose() {
    _client.close(force: true);
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.cpu,
    required this.mem,
    required this.net,
    required this.power,
    required this.events,
  });

  final double cpu;
  final double mem;
  final double net;
  final double power;
  final List<CalendarEvent> events;

  factory DashboardSnapshot.fromJson(Map<String, dynamic> json) {
    return DashboardSnapshot(
      cpu: parseDouble(json['cpu']),
      mem: parseDouble(json['mem']),
      net: parseDouble(json['net']),
      power: parseDouble(json['power']),
      events: switch (json['events']) {
        List<dynamic> list =>
          list
              .whereType<Map>()
              .map(
                (item) =>
                    CalendarEvent.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(),
        _ => const <CalendarEvent>[],
      },
    );
  }

  factory DashboardSnapshot.empty() {
    return const DashboardSnapshot(
      cpu: 0,
      mem: 0,
      net: 0,
      power: 0,
      events: [],
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DashboardSnapshot &&
        other.cpu == cpu &&
        other.mem == mem &&
        other.net == net &&
        other.power == power &&
        listEquals(other.events, events);
  }

  @override
  int get hashCode => Object.hash(
    cpu,
    mem,
    net,
    power,
    Object.hashAll(events),
  );
}

class ClockConfig {
  const ClockConfig({required this.zoneId, required this.colorId});

  final String zoneId;
  final String colorId;

  ClockConfig copyWith({String? zoneId, String? colorId}) {
    return ClockConfig(
      zoneId: zoneId ?? this.zoneId,
      colorId: colorId ?? this.colorId,
    );
  }

  Map<String, String> toJson() {
    return {'zoneId': zoneId, 'colorId': colorId};
  }

  static ClockConfig? fromJson(Map<String, dynamic> json) {
    final zoneId = json['zoneId']?.toString();
    final colorId = json['colorId']?.toString();
    if (zoneId == null || colorId == null) {
      return null;
    }
    if (!isValidClockZone(zoneId) || !isValidClockColor(colorId)) {
      return null;
    }
    return ClockConfig(zoneId: zoneId, colorId: colorId);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ClockConfig &&
        other.zoneId == zoneId &&
        other.colorId == colorId;
  }

  @override
  int get hashCode => Object.hash(zoneId, colorId);
}

class AvailabilitySettings {
  const AvailabilitySettings({
    required this.enabled,
    required this.workStartMinute,
    required this.workEndMinute,
    required this.minimumSlotMinutes,
  });

  final bool enabled;
  final int workStartMinute;
  final int workEndMinute;
  final int minimumSlotMinutes;

  static const defaults = AvailabilitySettings(
    enabled: true,
    workStartMinute: 9 * 60,
    workEndMinute: 18 * 60,
    minimumSlotMinutes: 30,
  );

  AvailabilitySettings copyWith({
    bool? enabled,
    int? workStartMinute,
    int? workEndMinute,
    int? minimumSlotMinutes,
  }) {
    return AvailabilitySettings(
      enabled: enabled ?? this.enabled,
      workStartMinute: workStartMinute ?? this.workStartMinute,
      workEndMinute: workEndMinute ?? this.workEndMinute,
      minimumSlotMinutes: minimumSlotMinutes ?? this.minimumSlotMinutes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'workStartMinute': workStartMinute,
      'workEndMinute': workEndMinute,
      'minimumSlotMinutes': minimumSlotMinutes,
    };
  }

  static AvailabilitySettings? fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    final start = json['workStartMinute'];
    final end = json['workEndMinute'];
    final minimum = json['minimumSlotMinutes'];
    final resolvedEnabled = enabled is bool ? enabled : true;
    if (start is! int || end is! int || minimum is! int) {
      return null;
    }
    if (start < 0 ||
        start >= 24 * 60 ||
        end <= 0 ||
        end > 24 * 60 ||
        end <= start ||
        minimum <= 0) {
      return null;
    }
    return AvailabilitySettings(
      enabled: resolvedEnabled,
      workStartMinute: start,
      workEndMinute: end,
      minimumSlotMinutes: minimum,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is AvailabilitySettings &&
        other.enabled == enabled &&
        other.workStartMinute == workStartMinute &&
        other.workEndMinute == workEndMinute &&
        other.minimumSlotMinutes == minimumSlotMinutes;
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    workStartMinute,
    workEndMinute,
    minimumSlotMinutes,
  );
}

class ClockZoneOption {
  const ClockZoneOption({
    required this.id,
    required this.label,
    required this.convert,
  });

  final String id;
  final String label;
  final DateTime Function(DateTime utc) convert;
}

const List<ClockConfig> defaultClockConfigs = [
  ClockConfig(zoneId: 'asia_kolkata', colorId: 'blue'),
  ClockConfig(zoneId: 'europe_berlin', colorId: 'green'),
  ClockConfig(zoneId: 'utc', colorId: 'white'),
  ClockConfig(zoneId: 'america_new_york', colorId: 'amber'),
];

final List<ClockZoneOption> clockZones = [
  ClockZoneOption(
    id: 'asia_kolkata',
    label: 'New Delhi',
    convert: (utc) => utc.add(const Duration(hours: 5, minutes: 30)),
  ),
  ClockZoneOption(id: 'europe_berlin', label: 'Munich', convert: berlinTime),
  ClockZoneOption(id: 'utc', label: 'UTC', convert: (utc) => utc),
  ClockZoneOption(id: 'europe_london', label: 'London', convert: londonTime),
  ClockZoneOption(
    id: 'america_new_york',
    label: 'New York',
    convert: newYorkTime,
  ),
  ClockZoneOption(
    id: 'america_chicago',
    label: 'Chicago',
    convert: chicagoTime,
  ),
  ClockZoneOption(
    id: 'america_los_angeles',
    label: 'San Francisco',
    convert: sanFranciscoTime,
  ),
  ClockZoneOption(
    id: 'asia_dubai',
    label: 'Dubai',
    convert: (utc) => utc.add(const Duration(hours: 4)),
  ),
  ClockZoneOption(
    id: 'asia_bangkok',
    label: 'Bangkok',
    convert: (utc) => utc.add(const Duration(hours: 7)),
  ),
  ClockZoneOption(
    id: 'asia_singapore',
    label: 'Singapore',
    convert: (utc) => utc.add(const Duration(hours: 8)),
  ),
  ClockZoneOption(
    id: 'asia_hong_kong',
    label: 'Hong Kong',
    convert: (utc) => utc.add(const Duration(hours: 8)),
  ),
  ClockZoneOption(
    id: 'asia_shanghai',
    label: 'Shanghai',
    convert: (utc) => utc.add(const Duration(hours: 8)),
  ),
  ClockZoneOption(
    id: 'asia_seoul',
    label: 'Seoul',
    convert: (utc) => utc.add(const Duration(hours: 9)),
  ),
  ClockZoneOption(
    id: 'asia_tokyo',
    label: 'Tokyo',
    convert: (utc) => utc.add(const Duration(hours: 9)),
  ),
];

const Map<String, Color> clockColors = {
  'blue': Palette.clockLocal,
  'green': Palette.clockTimezone,
  'cyan': Palette.cyan,
  'amber': Color(0xFFFFC857),
  'pink': Color(0xFFFF6B9A),
  'white': Palette.textPrimary,
};

class CalendarEvent {
  const CalendarEvent({
    required this.title,
    required this.location,
    required this.start,
    required this.end,
  });

  final String title;
  final String location;
  final DateTime? start;
  final DateTime? end;

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    return CalendarEvent(
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : '(No title)',
      location: (json['location'] as String?)?.trim() ?? '',
      start: parseIsoToLocal(json['from']),
      end: parseIsoToLocal(json['to']),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is CalendarEvent &&
        other.title == title &&
        other.location == location &&
        other.start == start &&
        other.end == end;
  }

  @override
  int get hashCode => Object.hash(title, location, start, end);
}

class DashboardMeetingGroup {
  DashboardMeetingGroup({required this.label, required this.events});

  final String label;
  final List<CalendarEvent> events;
}

List<CalendarEvent> parseCalendarEvents(dynamic raw) {
  final source = switch (raw) {
    Map<String, dynamic> map =>
      map['events'] is List
          ? map['events'] as List
          : map['data'] is List
          ? map['data'] as List
          : const [],
    List<dynamic> list => list,
    _ => const [],
  };

  return source
      .whereType<Map>()
      .map((item) => CalendarEvent.fromJson(Map<String, dynamic>.from(item)))
      .toList();
}

class Palette {
  static const Color background = Color(0xFF090C12);
  static const Color backgroundRaised = Color(0xFF101723);
  static const Color surface = Color(0xFF111723);
  static const Color surfaceRaised = Color(0xFF162133);
  static const Color cyan = Color(0xFF4CC9F0);
  static const Color highlight = Color(0xFF2FF3E0);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSubtle = Color(0xFFCCD9E6);
  static const Color clockLocal = Color(0xFF5F85F5);
  static const Color clockTimezone = Color(0xFF5FF580);
  static const Color calendarWeekday = Color(0xFFB3CCF2);
  static const Color calendarDay = Color(0xFFE5F2FF);
  static const Color today = Color(0xFF33FFE6);
  static const Color gaugeTrack = Color(0xFF26262E);
  static const Color gaugeAccent = Color(0xFFFF4D4D);
  static const Color gaugeTicks = Color(0xFFB3BFCC);
  static const Color progressGood = Color(0xFF2B8A2F);
  static const Color progressWarn = Color(0xFFFFBE3D);
  static const Color progressBad = Color(0xFFB3280C);
}

const List<String> weekdayLabels = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
const List<String> monthLabels = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const List<String> shortWeekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

final List<TextPainter> kGaugeNumberPainters = List<TextPainter>.generate(
  6,
  (index) => TextPainter(
    text: TextSpan(
      text: '${index * 2}',
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Color(0xFFD8E1EC),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(),
);

double parseDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

String sanitizeBaseUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

bool isValidBaseUrl(String value) {
  final sanitized = sanitizeBaseUrl(value);
  final uri = Uri.tryParse(sanitized);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

DateTime? parseIsoToLocal(dynamic value) {
  if (value == null) {
    return null;
  }
  final raw = value.toString().trim();
  if (raw.isEmpty) {
    return null;
  }
  final normalized = raw.endsWith('Z')
      ? '${raw.substring(0, raw.length - 1)}+00:00'
      : raw;
  try {
    return DateTime.parse(normalized).toLocal();
  } catch (_) {
    return null;
  }
}

List<CalendarEvent> validatedUpcomingEvents(List<CalendarEvent> events) {
  final now = DateTime.now().toLocal();
  final cutoff = now.subtract(kEventStartBuffer);
  final filtered = events.where((event) {
    if (event.start == null && event.end == null) {
      return false;
    }
    if (event.start != null && !event.start!.isAfter(cutoff)) {
      return false;
    }
    return true;
  }).toList();

  filtered.sort((a, b) {
    final aSort = a.start ?? a.end ?? now;
    final bSort = b.start ?? b.end ?? now;
    return aSort.compareTo(bSort);
  });
  return filtered;
}

List<CalendarEvent> eventsForDay(List<CalendarEvent> events, DateTime dayDate) {
  final dayStart = DateTime(dayDate.year, dayDate.month, dayDate.day).toLocal();
  final dayEnd = dayStart.add(const Duration(days: 1));

  final filtered = events.where((event) {
    final start = event.start;
    final end = event.end ?? start;
    if (start == null) {
      return false;
    }
    return end != null && end.isAfter(dayStart) && start.isBefore(dayEnd);
  }).toList();

  filtered.sort((a, b) {
    final aSort = a.start ?? a.end ?? dayStart;
    final bSort = b.start ?? b.end ?? dayStart;
    return aSort.compareTo(bSort);
  });

  return filtered;
}

class AgendaGroup {
  const AgendaGroup({
    required this.startMinute,
    required this.endMinute,
    required this.events,
  });

  final int startMinute;
  final int endMinute;
  final List<CalendarEvent> events;
}

List<AgendaGroup> agendaGroupsForDay(
  List<CalendarEvent> events,
  DateTime dayDate,
) {
  final groups = <AgendaGroup>[];
  for (final event in eventsForDay(events, dayDate)) {
    final start = event.start;
    final end = event.end ?? start;
    if (start == null || end == null) {
      continue;
    }
    final startMinute = (start.hour * 60) + start.minute;
    final endMinute = (end.hour * 60) + end.minute;
    if (groups.isNotEmpty && startMinute < groups.last.endMinute) {
      final previous = groups.removeLast();
      groups.add(
        AgendaGroup(
          startMinute: previous.startMinute,
          endMinute: math.max(previous.endMinute, endMinute),
          events: [...previous.events, event],
        ),
      );
    } else {
      groups.add(
        AgendaGroup(
          startMinute: startMinute,
          endMinute: endMinute,
          events: [event],
        ),
      );
    }
  }
  return groups;
}

class FreeSlot {
  const FreeSlot({required this.startMinute, required this.endMinute});

  final int startMinute;
  final int endMinute;

  int get durationMinutes => endMinute - startMinute;
}

class TimelineEntry {
  const TimelineEntry({
    required this.event,
    required this.startMinute,
    required this.endMinute,
    required this.columnIndex,
    required this.totalColumns,
  });

  final CalendarEvent event;
  final int startMinute;
  final int endMinute;
  final int columnIndex;
  final int totalColumns;
}

List<TimelineEntry> timelineItemsForDay(
  List<CalendarEvent> events,
  DateTime dayDate,
) {
  final dayStart = DateTime(dayDate.year, dayDate.month, dayDate.day).toLocal();
  final dayEnd = dayStart.add(const Duration(days: 1));

  final items = <(int, int, CalendarEvent)>[];
  for (final event in eventsForDay(events, dayDate)) {
    final start = event.start;
    final end = event.end ?? start;
    if (start == null || end == null) {
      continue;
    }
    final clippedStart = start.isBefore(dayStart) ? dayStart : start;
    final clippedEnd = end.isAfter(dayEnd) ? dayEnd : end;
    final startMinute = math.max(
      0,
      math.min(24 * 60, clippedStart.difference(dayStart).inMinutes),
    );
    final endMinute = math.max(
      startMinute + 5,
      math.max(0, math.min(24 * 60, clippedEnd.difference(dayStart).inMinutes)),
    );
    items.add((startMinute, endMinute, event));
  }

  items.sort((a, b) {
    final byStart = a.$1.compareTo(b.$1);
    if (byStart != 0) {
      return byStart;
    }
    return a.$2.compareTo(b.$2);
  });

  final laidOut = <TimelineEntry>[];
  var index = 0;
  while (index < items.length) {
    final group = <(int, int, CalendarEvent)>[items[index]];
    var groupEnd = items[index].$2;
    index += 1;

    while (index < items.length && items[index].$1 < groupEnd) {
      group.add(items[index]);
      groupEnd = math.max(groupEnd, items[index].$2);
      index += 1;
    }

    final columns = <int>[];
    final placements = <(int, int, CalendarEvent, int)>[];
    for (final item in group) {
      var placedColumn = -1;
      for (var i = 0; i < columns.length; i++) {
        if (item.$1 >= columns[i]) {
          columns[i] = item.$2;
          placedColumn = i;
          break;
        }
      }
      if (placedColumn == -1) {
        columns.add(item.$2);
        placedColumn = columns.length - 1;
      }
      placements.add((item.$1, item.$2, item.$3, placedColumn));
    }

    for (final placement in placements) {
      laidOut.add(
        TimelineEntry(
          event: placement.$3,
          startMinute: placement.$1,
          endMinute: placement.$2,
          columnIndex: placement.$4,
          totalColumns: columns.length,
        ),
      );
    }
  }

  return laidOut;
}

List<List<int?>> monthRows(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  final leading = first.weekday - DateTime.monday;
  final cells = <int?>[
    for (var i = 0; i < leading; i++) null,
    for (var day = 1; day <= daysInMonth; day++) day,
  ];

  while (cells.length % 7 != 0) {
    cells.add(null);
  }

  return [
    for (var index = 0; index < cells.length; index += 7)
      cells.sublist(index, index + 7),
  ];
}

String monthYearLabel(DateTime date) {
  return '${monthLabels[date.month - 1]} ${date.year}';
}

String timeLabel(DateTime date) {
  final hh = date.hour.toString().padLeft(2, '0');
  final mm = date.minute.toString().padLeft(2, '0');
  final ss = date.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

String apiDateLabel(DateTime date) {
  final local = date.toLocal();
  final yyyy = local.year.toString().padLeft(4, '0');
  final mm = local.month.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd';
}

String dayDateLabel(DateTime date) {
  return '${shortWeekdays[date.weekday - 1]}, '
      '${date.day.toString().padLeft(2, '0')} '
      '${monthLabels[date.month - 1]} ${date.year}';
}

String minuteLabel(int totalMinutes) {
  final hour = (totalMinutes ~/ 60).toString().padLeft(2, '0');
  final minute = (totalMinutes % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

const List<int> workMinuteOptions = [
  0,
  30,
  60,
  90,
  120,
  150,
  180,
  210,
  240,
  270,
  300,
  330,
  360,
  390,
  420,
  450,
  480,
  510,
  540,
  570,
  600,
  630,
  660,
  690,
  720,
  750,
  780,
  810,
  840,
  870,
  900,
  930,
  960,
  990,
  1020,
  1050,
  1080,
  1110,
  1140,
  1170,
  1200,
  1230,
  1260,
  1290,
  1320,
  1350,
  1380,
  1410,
  1440,
];

String durationLabel(int minutes) {
  if (minutes % 60 == 0) {
    final hours = minutes ~/ 60;
    return hours == 1 ? '1 hour' : '$hours hours';
  }
  if (minutes > 60) {
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    return '$hours h $rem m';
  }
  return '$minutes minutes';
}

List<FreeSlot> freeSlotsForDay(
  List<CalendarEvent> events,
  DateTime dayDate,
  AvailabilitySettings settings,
) {
  if (!settings.enabled) {
    return const [];
  }

  final dayEvents = eventsForDay(events, dayDate);
  final workStart = settings.workStartMinute;
  final workEnd = settings.workEndMinute;
  final busyRanges = <(int, int)>[];

  for (final event in dayEvents) {
    final start = event.start;
    final end = event.end ?? start;
    if (start == null || end == null) {
      continue;
    }
    final startMinute = math.max(workStart, (start.hour * 60) + start.minute);
    final endMinute = math.min(workEnd, (end.hour * 60) + end.minute);
    if (endMinute <= workStart || startMinute >= workEnd) {
      continue;
    }
    busyRanges.add((startMinute, math.max(startMinute, endMinute)));
  }

  busyRanges.sort((a, b) => a.$1.compareTo(b.$1));

  final merged = <(int, int)>[];
  for (final range in busyRanges) {
    if (merged.isEmpty || range.$1 > merged.last.$2) {
      merged.add(range);
    } else {
      final last = merged.removeLast();
      merged.add((last.$1, math.max(last.$2, range.$2)));
    }
  }

  final freeSlots = <FreeSlot>[];
  var cursor = workStart;
  for (final range in merged) {
    if (range.$1 - cursor >= settings.minimumSlotMinutes) {
      freeSlots.add(FreeSlot(startMinute: cursor, endMinute: range.$1));
    }
    cursor = math.max(cursor, range.$2);
  }
  if (workEnd - cursor >= settings.minimumSlotMinutes) {
    freeSlots.add(FreeSlot(startMinute: cursor, endMinute: workEnd));
  }

  if (merged.isEmpty && workEnd - workStart >= settings.minimumSlotMinutes) {
    return [FreeSlot(startMinute: workStart, endMinute: workEnd)];
  }
  return freeSlots;
}

String clockZoneLabel(String zoneId) {
  for (final zone in clockZones) {
    if (zone.id == zoneId) {
      return zone.label;
    }
  }
  return 'UTC';
}

Color clockColor(String colorId) {
  return clockColors[colorId] ?? Palette.textPrimary;
}

bool isValidClockZone(String zoneId) {
  return clockZones.any((zone) => zone.id == zoneId);
}

bool isValidClockColor(String colorId) {
  return clockColors.containsKey(colorId);
}

List<ClockConfig>? parseClockConfigs(List<String>? rawItems) {
  if (rawItems == null || rawItems.isEmpty) {
    return null;
  }

  final parsed = <ClockConfig>[];
  for (final raw in rawItems.take(4)) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final config = ClockConfig.fromJson(decoded);
      if (config == null) {
        return null;
      }
      parsed.add(config);
    } catch (_) {
      return null;
    }
  }

  if (parsed.isEmpty) {
    return null;
  }
  return parsed;
}

String clockColorLabel(String colorId) {
  switch (colorId) {
    case 'blue':
      return 'Blue';
    case 'green':
      return 'Green';
    case 'cyan':
      return 'Cyan';
    case 'amber':
      return 'Amber';
    case 'pink':
      return 'Pink';
    case 'white':
      return 'White';
    default:
      return 'White';
  }
}

String clockUtcOffsetLabel(String zoneId, DateTime utc) {
  final zoneTime = clockTimeForZone(zoneId, utc);
  final difference = zoneTime.difference(utc);
  final totalMinutes = difference.inMinutes;
  final sign = totalMinutes >= 0 ? '+' : '-';
  final absMinutes = totalMinutes.abs();
  final hours = (absMinutes ~/ 60).toString().padLeft(2, '0');
  final minutes = (absMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$minutes';
}

DateTime clockTimeForZone(String zoneId, DateTime utc) {
  for (final zone in clockZones) {
    if (zone.id == zoneId) {
      return zone.convert(utc);
    }
  }
  return utc;
}

DateTime londonTime(DateTime utc) {
  return utc.add(Duration(hours: isEuropeDst(utc) ? 1 : 0));
}

String formatEventSlot(DateTime? start, DateTime? end, String location) {
  if (start == null) {
    return location;
  }

  final datePart = isSameDay(start, DateTime.now())
      ? 'Today'
      : '${shortWeekdays[start.weekday - 1]}, '
            '${start.day.toString().padLeft(2, '0')} '
            '${monthLabels[start.month - 1].substring(0, 3)}';
  final startPart =
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
  final endPart = end == null
      ? ''
      : '-${end.hour.toString().padLeft(2, '0')}:'
            '${end.minute.toString().padLeft(2, '0')}';
  final locationPart = location.isEmpty ? '' : ' · $location';
  return '$datePart $startPart$endPart$locationPart';
}

String meetingStartLabel(CalendarEvent event) {
  final start = event.start;
  if (start == null) {
    return '--:--';
  }
  return '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
}

String minuteOfDayLabel(int minute) {
  final hour = (minute ~/ 60).clamp(0, 23);
  final mins = minute % 60;
  return '${hour.toString().padLeft(2, '0')}:'
      '${mins.toString().padLeft(2, '0')}';
}

String compactHourLabel(int minute) {
  final hour = (minute ~/ 60).clamp(0, 23);
  return '$hour';
}

List<DashboardMeetingGroup> dashboardMeetingGroups(List<CalendarEvent> events) {
  final groups = <DashboardMeetingGroup>[];

  for (final event in events) {
    final label = meetingStartLabel(event);
    if (groups.isNotEmpty && groups.last.label == label) {
      groups.last.events.add(event);
      continue;
    }
    groups.add(DashboardMeetingGroup(label: label, events: [event]));
  }

  return groups;
}

String timelineSlotLabel(CalendarEvent event) {
  final start = event.start;
  final end = event.end ?? start;
  if (start == null) {
    return event.location;
  }

  final startLabel =
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
  final endLabel = end == null
      ? ''
      : ' - ${end.hour.toString().padLeft(2, '0')}:'
            '${end.minute.toString().padLeft(2, '0')}';
  final location = event.location.isEmpty ? '' : ' · ${event.location}';
  return '$startLabel$endLabel$location';
}

String timelineTimeRangeLabel(CalendarEvent event) {
  final start = event.start;
  final end = event.end ?? start;
  if (start == null) {
    return '';
  }

  final startLabel =
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
  final endLabel = end == null
      ? ''
      : ' - ${end.hour.toString().padLeft(2, '0')}:'
            '${end.minute.toString().padLeft(2, '0')}';
  return '$startLabel$endLabel';
}

Color timelineAccentColor(CalendarEvent event) {
  const accents = [
    Palette.highlight,
    Palette.cyan,
    Palette.clockLocal,
    Palette.clockTimezone,
    Color(0xFFFFC857),
  ];
  final key = '${event.title}|${event.location}';
  final index = key.hashCode.abs() % accents.length;
  return accents[index];
}

bool isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

DateTime monthStart(DateTime date) => DateTime(date.year, date.month);

Color gaugeProgressColor(
  double value, {
  required bool reverse,
  bool networkStyle = false,
}) {
  if (networkStyle) {
    return value <= 0 ? Palette.progressBad : Palette.progressGood;
  }
  if (!reverse) {
    if (value < 50) {
      return Palette.progressGood;
    }
    if (value < 80) {
      return Palette.progressWarn;
    }
    return Palette.progressBad;
  }
  return value < 15 ? Palette.progressBad : Palette.progressGood;
}

String gaugeStatusLabel(double value) {
  if (value >= 85) {
    return 'HIGH';
  }
  if (value >= 60) {
    return 'STABLE';
  }
  if (value >= 30) {
    return 'NORMAL';
  }
  return 'LOW';
}

double degreesToRadians(double degrees) => degrees * (math.pi / 180);

DateTime berlinTime(DateTime utc) {
  final offsetHours = isBerlinDst(utc) ? 2 : 1;
  return utc.add(Duration(hours: offsetHours));
}

DateTime chicagoTime(DateTime utc) {
  final offsetHours = isUsCentralDst(utc) ? -5 : -6;
  return utc.add(Duration(hours: offsetHours));
}

DateTime newYorkTime(DateTime utc) {
  final offsetHours = isUsEasternDst(utc) ? -4 : -5;
  return utc.add(Duration(hours: offsetHours));
}

DateTime sanFranciscoTime(DateTime utc) {
  final offsetHours = isUsPacificDst(utc) ? -7 : -8;
  return utc.add(Duration(hours: offsetHours));
}

bool isBerlinDst(DateTime utc) {
  final year = utc.year;
  final start = DateTime.utc(year, 3, lastSundayOfMonth(year, 3), 1);
  final end = DateTime.utc(year, 10, lastSundayOfMonth(year, 10), 1);
  return !utc.isBefore(start) && utc.isBefore(end);
}

bool isEuropeDst(DateTime utc) => isBerlinDst(utc);

bool isUsCentralDst(DateTime utc) {
  final year = utc.year;
  final start = DateTime.utc(year, 3, nthSundayOfMonth(year, 3, 2), 8);
  final end = DateTime.utc(year, 11, nthSundayOfMonth(year, 11, 1), 7);
  return !utc.isBefore(start) && utc.isBefore(end);
}

bool isUsEasternDst(DateTime utc) {
  final year = utc.year;
  final start = DateTime.utc(year, 3, nthSundayOfMonth(year, 3, 2), 7);
  final end = DateTime.utc(year, 11, nthSundayOfMonth(year, 11, 1), 6);
  return !utc.isBefore(start) && utc.isBefore(end);
}

bool isUsPacificDst(DateTime utc) {
  final year = utc.year;
  final start = DateTime.utc(year, 3, nthSundayOfMonth(year, 3, 2), 10);
  final end = DateTime.utc(year, 11, nthSundayOfMonth(year, 11, 1), 9);
  return !utc.isBefore(start) && utc.isBefore(end);
}

int lastSundayOfMonth(int year, int month) {
  final lastDay = DateTime.utc(year, month + 1, 0);
  return lastDay.day - (lastDay.weekday % 7);
}

int nthSundayOfMonth(int year, int month, int nth) {
  final firstDay = DateTime.utc(year, month, 1);
  final offset = (7 - (firstDay.weekday % 7)) % 7;
  return 1 + offset + ((nth - 1) * 7);
}
