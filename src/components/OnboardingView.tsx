import React, { useEffect, useMemo, useRef, useState } from 'react';
import { AccessibilityInfo, Animated, Easing, Modal, PanResponder, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import * as Haptics from 'expo-haptics';
import Svg, { Circle, Defs, Line, LinearGradient, Path, Rect, Stop } from 'react-native-svg';
import { t, tf } from '../i18n';
import type { CameraProfile } from '../profiles/types';
import { FREE_UNLIMITED_PROFILE_ID } from '../monetization/CameraAccessPolicy';
import { IrisGlyph } from './IrisGlyph';

// Keep existing completions: this redesign is for first launch, not a forced tour.
export const CURRENT_ONBOARDING_VERSION = 1;
const ACCENT = '#E8B84B';
const INITIAL_OPENNESS = 0.64;
const clamp = (value: number) => Math.max(0, Math.min(1, value));

interface Props {
  visible: boolean;
  profiles: readonly CameraProfile[];
  apertureMode: 'unknown' | 'variable' | 'fixed';
  onComplete: (profileId: string) => void;
  onDismiss: () => void;
}

/** Two scenes, one instrument. Illustrations never render or alter a sample photo. */
export function OnboardingView({ visible, profiles, apertureMode, onComplete, onDismiss }: Props) {
  const [page, setPage] = useState(0);
  const [openness, setOpenness] = useState(INITIAL_OPENNESS);
  const [reduceMotion, setReduceMotion] = useState(false);
  const scene = useRef(new Animated.Value(0)).current;
  const completed = useRef(false);
  const { width, height } = useWindowDimensions();
  const heroSize = Math.max(180, Math.min(width - 40, height * 0.42, 340));
  const fixed = apertureMode === 'fixed';
  const freeProfile = profiles.find(p => p.id === FREE_UNLIMITED_PROFILE_ID);
  const initialProfile = freeProfile ?? profiles[0];
  const canStart = initialProfile != null;

  useEffect(() => {
    let active = true;
    AccessibilityInfo.isReduceMotionEnabled().then(value => { if (active) setReduceMotion(value); }).catch(() => {});
    const listener = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotion);
    return () => { active = false; listener.remove(); };
  }, []);

  useEffect(() => {
    if (!visible) return;
    completed.current = false;
    setPage(0);
    setOpenness(INITIAL_OPENNESS);
    scene.setValue(0);
  }, [visible, scene]);

  useEffect(() => {
    if (!visible) return;
    const animation = Animated.timing(scene, {
      toValue: page,
      duration: reduceMotion ? 0 : 520,
      easing: Easing.inOut(Easing.cubic),
      useNativeDriver: true,
    });
    animation.start();
    return () => animation.stop();
  }, [page, visible, reduceMotion, scene]);

  const finish = () => {
    if (completed.current || !initialProfile) return;
    completed.current = true;
    onComplete(initialProfile.id);
  };
  const advance = () => {
    if (page === 1) { finish(); return; }
    Haptics.selectionAsync().catch(() => {});
    setPage(1);
  };
  const title = page === 0 ? t(fixed ? 'onbFixedTitle' : 'onbApertureTitle') : t('onbQualityTitle');
  const subtitle = page === 0 ? t(fixed ? 'onbFixedSubtitle' : 'onbApertureSubtitle') : t('onbQualitySubtitle');

  return (
    <Modal animationType={reduceMotion ? 'none' : 'fade'} onRequestClose={finish} onDismiss={onDismiss} statusBarTranslucent visible={visible}>
      <View style={styles.root}>
        <View style={styles.navigation}>
          <Text style={styles.wordmark}>CAMERA 18</Text>
          <Pressable accessibilityRole="button" disabled={!canStart} onPress={page === 0 ? finish : () => setPage(0)} style={styles.navButton}>
            <Text style={styles.navText}>{t(page === 0 ? 'onbSkip' : 'onbBack')}</Text>
          </Pressable>
        </View>
        <ScrollView key={`${visible}-${page}`} style={styles.scroll} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
          <View style={styles.copy} accessibilityLiveRegion="polite">
            <Text accessibilityRole="header" style={styles.title}>{title}</Text>
            <Text style={styles.subtitle}>{subtitle}</Text>
          </View>
          <View style={{ width: heroSize, height: heroSize }}>
            <Animated.View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[StyleSheet.absoluteFillObject, { opacity: scene }]}>
              <CameraCollection profiles={profiles} />
            </Animated.View>
            <Animated.View
              pointerEvents={page === 0 && !fixed ? 'auto' : 'none'}
              accessibilityElementsHidden={page !== 0 || fixed}
              importantForAccessibility={page !== 0 || fixed ? 'no-hide-descendants' : 'auto'}
              style={[StyleSheet.absoluteFillObject, {
                transform: [
                  { translateY: scene.interpolate({ inputRange: [0, 1], outputRange: [0, heroSize * 0.05] }) },
                  { scale: scene.interpolate({ inputRange: [0, 1], outputRange: [1, 0.42] }) },
                ],
              }]}
            >
              <LensInstrument size={heroSize} openness={openness} interactive={visible && page === 0 && !fixed} onChange={setOpenness} />
            </Animated.View>
          </View>
          <View style={styles.caption}>
            <Text style={styles.captionTitle}>{page === 0 ? t(fixed ? 'onbFixedBadge' : 'onbStructureDemo') : tf('onbCameraCount', profiles.length)}</Text>
            <Text style={styles.captionDetail}>{page === 0 ? t(fixed ? 'onbFixedNote' : 'onbHardwareNote') : t('onbCharactersSubtitle')}</Text>
          </View>
        </ScrollView>
        <View style={styles.footer}>
          <View accessibilityLabel={`${page + 1} / 2`} style={styles.progress}>
            {[0, 1].map(index => <View key={index} style={[styles.dot, page === index && styles.activeDot]} />)}
          </View>
          <Pressable accessibilityRole="button" disabled={!canStart} onPress={advance} style={({ pressed }) => [styles.cta, pressed && styles.pressed, !canStart && styles.disabled]}>
            <Text style={styles.ctaText}>{t(page === 0 ? 'onbContinue' : 'onbStartShooting')}</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

/** Local mechanical demonstration only; never calls the camera or claims an f-stop. */
function LensInstrument({ size, openness, interactive, onChange }: { size: number; openness: number; interactive: boolean; onChange: (value: number) => void }) {
  const live = useRef({ size, openness, interactive, onChange });
  live.current = { size, openness, interactive, onChange };
  const previousAngle = useRef<number | null>(null);
  const lastTick = useRef(Math.round(openness * 12));
  const update = (value: number) => {
    const next = clamp(value);
    live.current.openness = next;
    live.current.onChange(next);
    const tick = Math.round(next * 12);
    if (tick !== lastTick.current) {
      lastTick.current = tick;
      Haptics.selectionAsync().catch(() => {});
    }
  };
  // One responder owns the entire turn; renders must not reset its angle anchor.
  const updateRef = useRef(update);
  updateRef.current = update;
  const responder = useMemo(() => PanResponder.create({
    onStartShouldSetPanResponder: event => live.current.interactive && event.nativeEvent.touches.length === 1,
    onPanResponderGrant: event => {
      const { locationX, locationY } = event.nativeEvent;
      const x = locationX - live.current.size / 2;
      const y = locationY - live.current.size / 2;
      previousAngle.current = Math.hypot(x, y) < live.current.size * 0.17 ? null : Math.atan2(y, x);
    },
    onPanResponderMove: (event, gesture) => {
      if (!live.current.interactive || gesture.numberActiveTouches !== 1) { previousAngle.current = null; return; }
      const x = event.nativeEvent.locationX - live.current.size / 2;
      const y = event.nativeEvent.locationY - live.current.size / 2;
      if (Math.hypot(x, y) < live.current.size * 0.17) { previousAngle.current = null; return; }
      const angle = Math.atan2(y, x);
      if (previousAngle.current != null) {
        const delta = Math.atan2(Math.sin(angle - previousAngle.current), Math.cos(angle - previousAngle.current));
        updateRef.current(live.current.openness - delta / Math.PI);
      }
      previousAngle.current = angle;
    },
    onPanResponderStart: (event, gesture) => { if (gesture.numberActiveTouches > 1) previousAngle.current = null; },
    onPanResponderRelease: () => { previousAngle.current = null; },
    onPanResponderTerminate: () => { previousAngle.current = null; },
  }), []);

  return (
    <View
      {...responder.panHandlers}
      accessible={interactive}
      accessibilityRole={interactive ? 'adjustable' : undefined}
      accessibilityLabel={interactive ? t('onbRingLabel') : undefined}
      accessibilityHint={interactive ? t('onbRingHint') : undefined}
      accessibilityValue={interactive ? { min: 0, max: 100, now: Math.round(openness * 100) } : undefined}
      accessibilityActions={interactive ? [{ name: 'increment' }, { name: 'decrement' }] : undefined}
      onAccessibilityAction={event => { if (interactive) update(openness + (event.nativeEvent.actionName === 'increment' ? 0.1 : -0.1)); }}
      style={{ width: size, height: size }}
    >
      <View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={StyleSheet.absoluteFillObject}>
        <Svg width={size} height={size} viewBox="0 0 340 340" accessible={false}>
          <Defs>
            <LinearGradient id="onb-metal" x1="0" y1="0" x2="1" y2="1">
              <Stop offset="0" stopColor="#85878A" /><Stop offset="0.24" stopColor="#35373B" /><Stop offset="0.64" stopColor="#101114" /><Stop offset="1" stopColor="#64666A" />
            </LinearGradient>
          </Defs>
          <Circle cx="170" cy="170" r="151" fill="#08090B" stroke="#282A2E" strokeWidth="2" />
          <Circle cx="170" cy="170" r="140" fill="url(#onb-metal)" stroke="#7E8084" strokeWidth="1" />
          <Circle cx="170" cy="170" r="126" fill="#121316" stroke="#484A4E" />
          {Array.from({ length: 64 }, (_, index) => {
            const a = index / 64 * Math.PI * 2;
            const outer = index % 4 === 0 ? 137 : 134;
            return <Line key={index} x1={170 + Math.sin(a) * 128} y1={170 - Math.cos(a) * 128} x2={170 + Math.sin(a) * outer} y2={170 - Math.cos(a) * outer} stroke="#A4A4A5" strokeWidth={index % 4 === 0 ? 1.4 : 0.7} opacity={index % 4 === 0 ? 0.9 : 0.4} />;
          })}
          <Circle cx="170" cy="170" r="111" fill="#07080A" stroke="#47494D" strokeWidth="2" />
          <Path d="M166 36L170 43L174 36Z" fill={ACCENT} />
        </Svg>
        <View style={{ position: 'absolute', left: size * 0.205, top: size * 0.205 }}>
          <IrisGlyph size={size * 0.59} openness={openness} accent="#B7AA8D" />
        </View>
        <View style={[StyleSheet.absoluteFillObject, { transform: [{ rotate: `${(1 - openness) * 120 - 60}deg` }] }]}>
          <View style={[styles.ringMarker, { top: size * 0.065, left: size / 2 - 2, height: size * 0.035 }]} />
        </View>
      </View>
    </View>
  );
}

function CameraCollection({ profiles }: { profiles: readonly CameraProfile[] }) {
  const accent = profiles.find(p => p.id === FREE_UNLIMITED_PROFILE_ID)?.ui?.accent ?? ACCENT;
  return (
    <Svg width="100%" height="100%" viewBox="0 0 340 340" accessible={false}>
      <Defs>
        <LinearGradient id="onb-body" x1="0" y1="0" x2="0.6" y2="1"><Stop offset="0" stopColor="#76787C" /><Stop offset="0.2" stopColor="#34363A" /><Stop offset="1" stopColor="#17181B" /></LinearGradient>
      </Defs>
      <Rect x="13" y="72" width="154" height="99" rx="15" fill="#24262A" stroke="#6C6E72" />
      <Rect x="22" y="81" width="135" height="17" rx="5" fill="#73767A" />
      <Circle cx="93" cy="130" r="30" fill="#111215" stroke="#777A7E" strokeWidth="4" />
      <Circle cx="93" cy="130" r="19" fill="#242B2D" stroke="#41494D" />
      <Rect x="177" y="65" width="149" height="112" rx="14" fill="#242528" stroke="#686A6D" />
      <Rect x="211" y="49" width="68" height="25" rx="6" fill="#505256" stroke="#777A7E" />
      <Circle cx="251" cy="122" r="35" fill="#0C0D10" stroke="#6C6F73" strokeWidth="5" />
      <Circle cx="251" cy="122" r="23" fill="#25282E" stroke="#43484C" />
      <Rect x="36" y="131" width="268" height="148" rx="20" fill="url(#onb-body)" stroke="#8B8C8E" />
      <Rect x="46" y="162" width="248" height="103" rx="12" fill="#17181B" />
      <Rect x="57" y="119" width="39" height="14" rx="5" fill="#777A7E" />
      <Rect x="248" y="122" width="32" height="10" rx="4" fill="#C5C3BC" />
      <Rect x="55" y="144" width="33" height="12" rx="4" fill="#0D1013" stroke="#9D9E9C" />
      <Circle cx="282" cy="151" r="4" fill={accent} />
      <Path d="M50 252H76M50 243H76M50 234H76M50 225H76" stroke="#46484B" strokeWidth="2" />
    </Svg>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0A0A0C', paddingTop: 56 },
  navigation: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 28, minHeight: 44 },
  wordmark: { color: '#B9B8B4', fontSize: 11, fontWeight: '700', letterSpacing: 3 },
  navButton: { minHeight: 44, minWidth: 54, alignItems: 'flex-end', justifyContent: 'center' },
  navText: { color: '#B9B8B4', fontSize: 13 },
  scroll: { flex: 1 },
  content: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', paddingTop: 16, paddingBottom: 20 },
  copy: { alignItems: 'center', paddingHorizontal: 28, marginBottom: 16, maxWidth: 540 },
  title: { color: '#FAF8F2', fontSize: 32, fontWeight: '700', lineHeight: 41, textAlign: 'center', letterSpacing: -0.8 },
  subtitle: { color: '#ABA9A4', fontSize: 15, lineHeight: 24, marginTop: 14, textAlign: 'center', maxWidth: 350 },
  caption: { alignItems: 'center', paddingHorizontal: 32, gap: 8, marginTop: 12, maxWidth: 470 },
  captionTitle: { color: '#D3C7AA', fontSize: 12, fontWeight: '600', letterSpacing: 1.2, textAlign: 'center' },
  captionDetail: { color: '#979590', fontSize: 12, lineHeight: 19, textAlign: 'center' },
  footer: { paddingHorizontal: 28, paddingTop: 8, paddingBottom: 34, alignItems: 'center', gap: 20 },
  progress: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  dot: { width: 5, height: 5, borderRadius: 3, backgroundColor: '#4C4B48' },
  activeDot: { width: 19, backgroundColor: ACCENT },
  cta: { width: '100%', maxWidth: 390, minHeight: 54, paddingVertical: 14, paddingHorizontal: 24, justifyContent: 'center', alignItems: 'center', borderRadius: 17, backgroundColor: '#E8B84B' },
  ctaText: { color: '#17140E', fontSize: 16, fontWeight: '700', textAlign: 'center' },
  pressed: { opacity: 0.75 },
  disabled: { opacity: 0.45 },
  ringMarker: { position: 'absolute', width: 4, borderRadius: 2, backgroundColor: ACCENT },
});
