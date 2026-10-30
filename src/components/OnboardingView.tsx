import React, { useMemo, useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import Svg, { Circle, Defs, Ellipse, LinearGradient, Path, Rect, Stop } from 'react-native-svg';
import { appLang } from '../i18n';
import { MONETIZATION_ENABLED } from '../monetization/MonetizationConfig';
import type { CameraProfile } from '../profiles/types';

// Preserve version 1: returning users who finished the old intro are not interrupted.
export const CURRENT_ONBOARDING_VERSION = 1;
const IDS = ['ricoh_negative', 'canon_portrait', 'leica_m9'] as const;
const DESCRIPTIONS = {
  ricoh_negative: ['Cool negative', '清冷负片'],
  canon_portrait: ['Warm portrait', '温暖人像'],
  leica_m9: ['Rich documentary', '浓郁纪实'],
} as const;

interface Props {
  visible: boolean;
  profiles: readonly CameraProfile[];
  finder: { width: number; height: number };
  onComplete: (profileId: string) => void;
  onDismiss: () => void;
}

export function OnboardingView({ visible, profiles, finder, onComplete, onDismiss }: Props) {
  const [selected, setSelected] = useState<string>(IDS[0]);
  const options = useMemo(() => IDS.map(id => profiles.find(p => p.id === id)).filter((p): p is CameraProfile => !!p), [profiles]);
  const zh = appLang === 'zh';

  const selectedProfile = options.find(p => p.id === selected);
  return (
    <Modal animationType="fade" onRequestClose={() => onComplete(selected)} onDismiss={onDismiss} statusBarTranslucent visible={visible}>
      <ScrollView contentContainerStyle={styles.page} style={styles.root}>
        <Text style={styles.title}>{zh ? '用 iPhone，拍出相机的性格。' : 'Give your iPhone a camera character.'}</Text>
        <Text style={styles.subtitle}>{zh ? '自然光影，细腻质感。' : 'Natural light. Refined detail.'}</Text>
        <View style={[styles.picture, { width: finder.width, height: finder.height }]}>
          <OnboardingPlaceholder />
          <Text style={styles.sample}>{zh ? '矢量占位图' : 'VECTOR PLACEHOLDER'}</Text>
        </View>
        <Text style={styles.note}>{zh ? '仅预览页面布局，非实际相机效果。' : 'Layout preview only. Not an actual camera rendering.'}</Text>
        <View style={styles.options}>
          {options.map(profile => {
            const id = profile.id as keyof typeof DESCRIPTIONS;
            const active = selected === id;
            return <Pressable key={id} accessibilityRole="radio" accessibilityState={{ selected: active }} onPress={() => setSelected(id)} style={[styles.option, active && { borderColor: profile.ui?.accent || '#fff' }]}>
              <Text style={styles.optionName}>{profile.name}</Text>
              <Text style={styles.optionDescription}>{DESCRIPTIONS[id][zh ? 1 : 0]}</Text>
            </Pressable>;
          })}
        </View>
        <Pressable accessibilityRole="button" onPress={() => onComplete(selected)} style={[styles.cta, { backgroundColor: selectedProfile?.ui?.accent || '#E8B84B' }]}>
          <Text style={styles.ctaText}>{zh ? '用这台相机拍照' : 'Shoot with this camera'}</Text>
        </Pressable>
        {MONETIZATION_ENABLED ? <Text style={styles.note}>{zh ? 'GRIT N 永久免费 · 其他相机各试拍 3 张' : 'GRIT N is free · Try each other camera with 3 shots'}</Text> : null}
      </ScrollView>
    </Modal>
  );
}

// Inline vector art: no external asset, network request, or native photo render.
// Keep it neutral so this layout placeholder cannot imply a real camera result.
function OnboardingPlaceholder() {
  return (
    <Svg width="100%" height="100%" viewBox="0 0 400 600" preserveAspectRatio="xMidYMid slice" accessible={false}>
      <Defs>
        <LinearGradient id="wall" x1="0" y1="0" x2="1" y2="1">
          <Stop offset="0" stopColor="#E8E1D5" /><Stop offset="1" stopColor="#BEB9AE" />
        </LinearGradient>
        <LinearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
          <Stop offset="0" stopColor="#B6CAD0" /><Stop offset="1" stopColor="#E7E4D7" />
        </LinearGradient>
        <LinearGradient id="vase" x1="0" y1="0" x2="1" y2="0">
          <Stop offset="0" stopColor="#A36349" /><Stop offset="0.5" stopColor="#D29973" /><Stop offset="1" stopColor="#B37959" />
        </LinearGradient>
      </Defs>
      <Rect width="400" height="600" fill="url(#wall)" />
      <Rect x="34" y="52" width="234" height="306" rx="116" fill="#F3EDE0" />
      <Path d="M48 344V170a103 103 0 0 1 206 0v174Z" fill="url(#sky)" />
      <Circle cx="197" cy="144" r="32" fill="#F9EDD0" />
      <Path d="M48 288Q116 213 185 276T254 268V344H48Z" fill="#8D9D91" />
      <Path d="M48 320Q117 268 178 314T254 304V344H48Z" fill="#637C75" />
      <Path d="M151 66V344M48 224H254" stroke="#F3EDE0" strokeWidth="10" />
      <Path d="M254 358 400 465V600H100Z" fill="#F8EDCF" opacity="0.32" />
      <Rect y="447" width="400" height="153" fill="#B29C80" />
      <Path d="M0 449H400" stroke="#D4C5AC" strokeWidth="4" />
      <Ellipse cx="256" cy="510" rx="99" ry="18" fill="#564F43" opacity="0.17" />
      <Path d="M244 424Q217 342 206 260M250 426Q256 322 293 235M248 389Q287 337 320 318" fill="none" stroke="#536D54" strokeWidth="5" strokeLinecap="round" />
      <Path d="M220 333Q168 330 180 293Q220 292 220 333M259 326Q255 275 289 276Q304 309 259 326M283 280Q275 234 311 215Q324 252 283 280M283 353Q306 309 338 324Q328 359 283 353M208 278Q173 274 181 244Q210 243 208 278" fill="#73866A" />
      <Path d="M220 405H272L270 432Q306 459 291 497Q279 519 246 519Q212 519 200 497Q185 459 222 432Z" fill="url(#vase)" />
      <Ellipse cx="246" cy="405" rx="26" ry="6" fill="#89563F" />
      <Rect x="45" y="486" width="107" height="17" rx="3" fill="#ECE2CD" />
      <Rect x="52" y="470" width="101" height="16" rx="3" fill="#697C7A" />
      <Path d="M61 478H143" stroke="#95A4A0" strokeWidth="2" />
    </Svg>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0A0A0C' },
  page: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 46 },
  title: { color: '#fff', fontSize: 23, fontWeight: '700', textAlign: 'center' },
  subtitle: { color: 'rgba(255,255,255,0.7)', fontSize: 14, marginTop: 8, marginBottom: 16, textAlign: 'center' },
  picture: { borderRadius: 28, overflow: 'hidden', backgroundColor: '#202023' },
  sample: { position: 'absolute', top: 14, left: 14, color: '#fff', fontSize: 11, fontWeight: '700', backgroundColor: 'rgba(0,0,0,0.55)', paddingHorizontal: 9, paddingVertical: 5, overflow: 'hidden', borderRadius: 8 },
  options: { width: '90%', maxWidth: 390, flexDirection: 'row', gap: 8, marginTop: 14 },
  option: { flex: 1, minHeight: 58, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)', borderRadius: 12, paddingHorizontal: 3 },
  optionName: { color: '#fff', fontSize: 13, fontWeight: '700' },
  optionDescription: { color: 'rgba(255,255,255,0.7)', fontSize: 11, marginTop: 4, textAlign: 'center' },
  cta: { marginTop: 16, width: '90%', maxWidth: 390, minHeight: 50, justifyContent: 'center', alignItems: 'center', borderRadius: 14 },
  ctaText: { color: '#111', fontSize: 15, fontWeight: '700' },
  note: { color: 'rgba(255,255,255,0.65)', fontSize: 11, marginTop: 10, textAlign: 'center' },
});
