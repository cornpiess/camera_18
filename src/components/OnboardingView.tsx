import React, { useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Image, Modal, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Asset } from 'expo-asset';
import { CameraEngine } from '../camera/CameraEngine';
import { appLang } from '../i18n';
import { MONETIZATION_ENABLED } from '../monetization/MonetizationConfig';
import type { CameraProfile } from '../profiles/types';

// Preserve version 1: returning users who finished the old intro are not interrupted.
export const CURRENT_ONBOARDING_VERSION = 1;
const EXAMPLE = require('../../assets/onboarding/source.png');
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
  const [images, setImages] = useState<Record<string, string>>({});
  const [original, setOriginal] = useState(false);
  const [failed, setFailed] = useState(false);
  const options = useMemo(() => IDS.map(id => profiles.find(p => p.id === id)).filter((p): p is CameraProfile => !!p), [profiles]);
  const zh = appLang === 'zh';

  useEffect(() => {
    if (!visible || options.length === 0) return;
    let active = true;
    void (async () => {
      try {
        const asset = Asset.fromModule(EXAMPLE);
        await asset.downloadAsync();
        if (!asset.localUri) throw new Error('Example image unavailable');
        // Serialize full-resolution renders to bound memory; never block taking photos.
        for (const profile of options) {
          if (!active) return;
          const uri = await CameraEngine.renderOnboardingExample(asset.localUri, profile as unknown as Record<string, unknown>);
          if (active) setImages(current => ({ ...current, [profile.id]: uri }));
        }
      } catch {
        if (active) setFailed(true);
      }
    })();
    return () => { active = false; };
  }, [visible, options]);

  const selectedProfile = options.find(p => p.id === selected);
  const image = images[selected];
  return (
    <Modal animationType="fade" onRequestClose={() => onComplete(selected)} onDismiss={onDismiss} statusBarTranslucent visible={visible}>
      <ScrollView contentContainerStyle={styles.page} style={styles.root}>
        <Text style={styles.title}>{zh ? '用 iPhone，拍出相机的性格。' : 'Give your iPhone a camera character.'}</Text>
        <Text style={styles.subtitle}>{zh ? '自然光影，细腻质感。' : 'Natural light. Refined detail.'}</Text>
        <View style={[styles.picture, { width: finder.width, height: finder.height }]}>
          <Image source={original || !image ? EXAMPLE : { uri: image }} style={styles.image} resizeMode="cover" />
          <Text style={styles.sample}>{original || !image ? (zh ? '示例原图' : 'EXAMPLE ORIGINAL') : (zh ? '示例' : 'EXAMPLE')}</Text>
          {image ? (
            <Pressable accessibilityRole="button" accessibilityLabel={zh ? '切换示例原图与相机效果' : 'Toggle example original and camera look'} onPressIn={() => setOriginal(true)} onPressOut={() => setOriginal(false)} onAccessibilityTap={() => setOriginal(value => !value)} style={styles.compare}>
              <Text style={styles.compareText}>{original ? (zh ? '示例原图' : 'ORIGINAL') : (zh ? '按住对比' : 'HOLD TO COMPARE')}</Text>
            </Pressable>
          ) : !failed ? <View style={styles.loading}><ActivityIndicator color="#fff" /></View> : null}
        </View>
        {failed ? <Text style={styles.note}>{zh ? '示例暂不可用，仍可直接拍照。' : 'Example unavailable. You can still start shooting.'}</Text> : null}
        <View style={styles.options}>
          {options.map(profile => {
            const id = profile.id as keyof typeof DESCRIPTIONS;
            const active = selected === id;
            return <Pressable key={id} accessibilityRole="radio" accessibilityState={{ selected: active }} onPress={() => { setSelected(id); setOriginal(false); }} style={[styles.option, active && { borderColor: profile.ui?.accent || '#fff' }]}>
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

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0A0A0C' },
  page: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', paddingVertical: 46 },
  title: { color: '#fff', fontSize: 23, fontWeight: '700', textAlign: 'center' },
  subtitle: { color: 'rgba(255,255,255,0.7)', fontSize: 14, marginTop: 8, marginBottom: 16, textAlign: 'center' },
  picture: { borderRadius: 28, overflow: 'hidden', backgroundColor: '#202023' },
  image: { width: '100%', height: '100%' },
  sample: { position: 'absolute', top: 14, left: 14, color: '#fff', fontSize: 11, fontWeight: '700', backgroundColor: 'rgba(0,0,0,0.55)', paddingHorizontal: 9, paddingVertical: 5, overflow: 'hidden', borderRadius: 8 },
  compare: { position: 'absolute', right: 8, bottom: 8, minHeight: 44, paddingHorizontal: 12, justifyContent: 'center', borderRadius: 14, backgroundColor: 'rgba(0,0,0,0.65)' },
  compareText: { color: '#fff', fontSize: 11, fontWeight: '700' },
  loading: { position: 'absolute', right: 14, bottom: 14 },
  options: { width: '90%', maxWidth: 390, flexDirection: 'row', gap: 8, marginTop: 14 },
  option: { flex: 1, minHeight: 58, alignItems: 'center', justifyContent: 'center', borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)', borderRadius: 12, paddingHorizontal: 3 },
  optionName: { color: '#fff', fontSize: 13, fontWeight: '700' },
  optionDescription: { color: 'rgba(255,255,255,0.7)', fontSize: 11, marginTop: 4, textAlign: 'center' },
  cta: { marginTop: 16, width: '90%', maxWidth: 390, minHeight: 50, justifyContent: 'center', alignItems: 'center', borderRadius: 14 },
  ctaText: { color: '#111', fontSize: 15, fontWeight: '700' },
  note: { color: 'rgba(255,255,255,0.65)', fontSize: 11, marginTop: 10, textAlign: 'center' },
});
