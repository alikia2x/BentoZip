import React, { useEffect, useState } from 'react';
import {
  ArrowDownToLine,
  Check,
  ChevronRight,
  Download,
  Eye,
  FileArchive,
  FolderOpen,
  KeyRound,
  Layers,
  Lock,
  Sparkles,
  Zap,
} from 'lucide-react';
import { COPY, RELEASE_URL, REPO_URL, type Lang } from '../data/copy';
import { FORMATS, type FormatCategory } from '../data/formats';

type FilterTab = 'all' | FormatCategory;

export default function BentoZipSite() {
  const [lang, setLang] = useState<Lang>('en');
  const [activeStage, setActiveStage] = useState<'workspace' | 'inspector' | 'tasks' | 'welcome'>('workspace');
  const [activeFormatTab, setActiveFormatTab] = useState<FilterTab>('all');

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const queryLang = params.get('lang');
    const saved = window.localStorage.getItem('bentozip-lang');
    if (queryLang === 'zh' || queryLang === 'en') {
      setLang(queryLang);
    } else if (saved === 'zh' || saved === 'en') {
      setLang(saved);
    }
  }, []);

  useEffect(() => {
    document.documentElement.lang = lang === 'zh' ? 'zh-Hans' : 'en';
    document.title = COPY[lang].meta.title;
    window.localStorage.setItem('bentozip-lang', lang);
  }, [lang]);

  const t = COPY[lang];
  const currentStage = t.hero.stages.find((s) => s.id === activeStage) ?? t.hero.stages[0];

  const filteredFormats =
    activeFormatTab === 'all'
      ? FORMATS
      : FORMATS.filter((item) => item.category === activeFormatTab);

  return (
    <div className="min-h-screen bg-[#FAFAF8] text-[#111113]">
      {/* Sticky Minimal Navigation */}
      <header className="sticky top-0 z-40 border-b border-[rgba(17,17,19,0.08)] bg-[#FAFAF8]/85 backdrop-blur-md">
        <div className="mx-auto flex h-14 max-w-[1120px] items-center justify-between px-5 sm:px-8">
          <a href="#" className="flex items-center gap-2.5 text-[#111113] no-underline">
            <img
              src="/images/app-icon.png"
              alt="BentoZip icon"
              width={28}
              height={28}
              className="h-7 w-7 rounded-[7px] shadow-[0_1px_3px_rgba(17,17,19,0.12)]"
            />
            <span className="text-[15px] font-semibold tracking-[-0.02em]">BentoZip</span>
          </a>

          <nav className="hidden items-center gap-7 text-[13.5px] font-medium text-[#5C5C62] md:flex">
            <a href="#features" className="transition-colors hover:text-[#111113]">
              {t.nav.features}
            </a>
            <a href="#formats" className="transition-colors hover:text-[#111113]">
              {t.nav.formats}
            </a>
            <a href="#craft" className="transition-colors hover:text-[#111113]">
              {t.nav.craft}
            </a>
          </nav>

          <div className="flex items-center gap-2.5 sm:gap-3">
            <div
              role="group"
              aria-label="Language"
              className="inline-flex items-center rounded-full border border-[rgba(17,17,19,0.09)] bg-[#F3F3F1] p-0.5 text-[12px] font-medium"
            >
              <button
                type="button"
                onClick={() => setLang('en')}
                className={`rounded-full px-2.5 py-1 transition-all ${
                  lang === 'en'
                    ? 'bg-white text-[#111113] shadow-[0_1px_2px_rgba(17,17,19,0.08)]'
                    : 'text-[#5C5C62] hover:text-[#111113]'
                }`}
              >
                EN
              </button>
              <button
                type="button"
                onClick={() => setLang('zh')}
                className={`rounded-full px-2.5 py-1 transition-all ${
                  lang === 'zh'
                    ? 'bg-white text-[#111113] shadow-[0_1px_2px_rgba(17,17,19,0.08)]'
                    : 'text-[#5C5C62] hover:text-[#111113]'
                }`}
              >
                中文
              </button>
            </div>

            <a
              href={RELEASE_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex h-8 items-center gap-1.5 rounded-full bg-[#0071E3] px-3.5 text-[13px] font-medium text-white transition-colors hover:bg-[#0077ED]"
            >
              <Download className="h-3.5 w-3.5" strokeWidth={2} />
              <span>{t.nav.download}</span>
            </a>
          </div>
        </div>
      </header>

      <main>
        {/* Editorial Hero + Interactive Product Stage */}
        <section className="mx-auto max-w-[1120px] px-5 pt-14 pb-16 sm:px-8 sm:pt-20 sm:pb-24">
          <div className="mx-auto max-w-[780px] text-center">
            <div className="mb-5 inline-flex items-center gap-2 rounded-full border border-[rgba(17,17,19,0.08)] bg-white px-3.5 py-1 text-[12px] font-medium text-[#5C5C62]">
              <span className="h-1.5 w-1.5 rounded-full bg-[#0071E3]" />
              <span>{t.hero.badge}</span>
            </div>

            <h1 className="text-[36px] font-semibold tracking-[-0.032em] leading-[1.08] text-[#111113] sm:text-[54px]">
              {t.hero.headline}
            </h1>

            <p className="mx-auto mt-5 max-w-[640px] text-[16.5px] leading-[1.6] text-[#5C5C62] sm:text-[18.5px]">
              {t.hero.subcopy}
            </p>

            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              <a
                href={RELEASE_URL}
                target="_blank"
                rel="noreferrer"
                className="inline-flex h-11 items-center gap-2 rounded-full bg-[#0071E3] px-6 text-[14.5px] font-medium text-white shadow-[0_2px_10px_rgba(0,113,227,0.22)] transition-all hover:bg-[#0077ED]"
              >
                <ArrowDownToLine className="h-4 w-4" strokeWidth={2} />
                <span>{t.hero.primaryCta}</span>
              </a>
              <a
                href="#formats"
                className="inline-flex h-11 items-center gap-1.5 rounded-full border border-[rgba(17,17,19,0.1)] bg-white px-5 text-[14.5px] font-medium text-[#111113] transition-colors hover:bg-[#F3F3F1]"
              >
                <span>{t.hero.secondaryCta}</span>
                <ChevronRight className="h-4 w-4 text-[#5C5C62]" />
              </a>
            </div>

            <p className="mt-3.5 text-[12.5px] text-[#5C5C62]">{t.hero.footnote}</p>
          </div>

          {/* Interactive Product Stage */}
          <div className="mt-12 sm:mt-14">
            <div className="mb-5 flex justify-center">
              <div
                role="tablist"
                aria-label="Product views"
                className="inline-flex flex-wrap justify-center gap-1 rounded-2xl border border-[rgba(17,17,19,0.08)] bg-[#F3F3F1] p-1 sm:rounded-full"
              >
                {t.hero.stages.map((stage) => {
                  const active = stage.id === activeStage;
                  return (
                    <button
                      key={stage.id}
                      type="button"
                      role="tab"
                      aria-selected={active}
                      onClick={() => setActiveStage(stage.id)}
                      className={`rounded-full px-4 py-1.5 text-[13px] font-medium transition-all ${
                        active
                          ? 'bg-white text-[#111113] shadow-[0_1px_3px_rgba(17,17,19,0.09)]'
                          : 'text-[#5C5C62] hover:text-[#111113]'
                      }`}
                    >
                      {stage.label}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="overflow-hidden rounded-2xl border border-[rgba(17,17,19,0.09)] bg-[#F2F2EF] shadow-[0_24px_60px_rgba(17,17,19,0.07)]">
              <div className="relative aspect-[1080/680] w-full bg-[#F2F2EF]">
                <img
                  key={currentStage.id}
                  src={currentStage.image}
                  alt={currentStage.alt}
                  className="h-full w-full object-cover"
                />
              </div>
            </div>

            <p className="mx-auto mt-4 max-w-[680px] text-center text-[13.5px] leading-[1.55] text-[#5C5C62]">
              {currentStage.caption}
            </p>
          </div>
        </section>

        {/* Focused Feature Bento Grid */}
        <section id="features" className="border-t border-[rgba(17,17,19,0.08)] bg-white/50 py-20 sm:py-24">
          <div className="mx-auto max-w-[1120px] px-5 sm:px-8">
            <div className="max-w-[660px]">
              <p className="text-[12.5px] font-semibold uppercase tracking-[0.06em] text-[#0071E3]">
                {t.bento.eyebrow}
              </p>
              <h2 className="mt-2.5 text-[28px] font-semibold tracking-[-0.025em] leading-[1.15] text-[#111113] sm:text-[38px]">
                {t.bento.title}
              </h2>
              <p className="mt-3 text-[16px] leading-[1.6] text-[#5C5C62]">{t.bento.subtitle}</p>
            </div>

            <div className="mt-12 grid grid-cols-1 gap-5 lg:grid-cols-12">
              {/* Card 1: Quick Look & Drag-Out (7 cols) */}
              <div className="flex flex-col justify-between rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-7 lg:col-span-7">
                <div>
                  <div className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#0071E3]">
                    <Eye className="h-3.5 w-3.5" />
                    <span>{t.bento.cards.quickLook.eyebrow}</span>
                  </div>
                  <h3 className="mt-2.5 text-[22px] font-semibold tracking-[-0.02em] text-[#111113]">
                    {t.bento.cards.quickLook.title}
                  </h3>
                  <p className="mt-2.5 max-w-[540px] text-[14.5px] leading-[1.6] text-[#5C5C62]">
                    {t.bento.cards.quickLook.body}
                  </p>
                </div>

                {/* Clean macOS interaction visual */}
                <div className="mt-7 rounded-xl border border-[rgba(17,17,19,0.08)] bg-[#FAFAF8] p-4">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="flex items-center gap-3">
                      <div className="flex h-10 w-10 items-center justify-center rounded-lg border border-[rgba(17,17,19,0.08)] bg-white shadow-[0_1px_2px_rgba(17,17,19,0.04)]">
                        <FileArchive className="h-5 w-5 text-[#0071E3]" strokeWidth={1.75} />
                      </div>
                      <div>
                        <div className="font-mono text-[12.5px] font-medium text-[#111113]">
                          OutlineRow.swift
                        </div>
                        <div className="text-[11.5px] text-[#5C5C62]">
                          Design-System-v4.2.tar.gz / Components
                        </div>
                      </div>
                    </div>

                    <div className="flex flex-wrap items-center gap-2">
                      <span className="inline-flex items-center gap-1.5 rounded-lg border border-[rgba(17,17,19,0.09)] bg-white px-2.5 py-1 text-[11.5px] font-medium text-[#111113]">
                        <span className="keycap !h-5 !min-w-[42px] !text-[10px]">Space</span>
                        <span>{t.bento.cards.quickLook.hintSpace}</span>
                      </span>
                    </div>
                  </div>
                  <div className="mt-3 flex items-center gap-2 border-t border-[rgba(17,17,19,0.06)] pt-2.5 text-[12px] text-[#5C5C62]">
                    <FolderOpen className="h-3.5 w-3.5 text-[#0071E3]" />
                    <span>{t.bento.cards.quickLook.hintDrag}</span>
                  </div>
                </div>
              </div>

              {/* Card 2: Independent Tasks Window (5 cols) */}
              <div className="flex flex-col justify-between rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-7 lg:col-span-5">
                <div>
                  <div className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#0071E3]">
                    <Layers className="h-3.5 w-3.5" />
                    <span>{t.bento.cards.tasks.eyebrow}</span>
                  </div>
                  <h3 className="mt-2.5 text-[22px] font-semibold tracking-[-0.02em] text-[#111113]">
                    {t.bento.cards.tasks.title}
                  </h3>
                  <p className="mt-2.5 text-[14.5px] leading-[1.6] text-[#5C5C62]">
                    {t.bento.cards.tasks.body}
                  </p>
                </div>

                <div className="mt-7 rounded-xl border border-[rgba(17,17,19,0.08)] bg-[#FAFAF8] p-4">
                  <div className="flex items-center justify-between text-[12px] font-medium text-[#111113]">
                    <span className="truncate">Release-Kit-v2.4.zip</span>
                    <span className="font-mono text-[#5C5C62]">64%</span>
                  </div>
                  <div className="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-[rgba(17,17,19,0.08)]">
                    <div className="h-full w-[64%] rounded-full bg-[#0071E3]" />
                  </div>
                  <div className="mt-4 grid grid-cols-3 gap-2 border-t border-[rgba(17,17,19,0.06)] pt-3">
                    {t.bento.cards.tasks.metrics.map((m) => (
                      <div key={m.label}>
                        <div className="text-[10.5px] text-[#5C5C62]">{m.label}</div>
                        <div className="font-mono text-[13px] font-semibold text-[#111113]">
                          {m.value}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>

              {/* Card 3: Smart Local Caching (6 cols) */}
              <div className="flex flex-col justify-between rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-7 lg:col-span-6">
                <div>
                  <div className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#0071E3]">
                    <Zap className="h-3.5 w-3.5" />
                    <span>{t.bento.cards.cache.eyebrow}</span>
                  </div>
                  <h3 className="mt-2.5 text-[21px] font-semibold tracking-[-0.02em] text-[#111113]">
                    {t.bento.cards.cache.title}
                  </h3>
                  <p className="mt-2.5 text-[14.5px] leading-[1.6] text-[#5C5C62]">
                    {t.bento.cards.cache.body}
                  </p>
                </div>

                <div className="mt-7 space-y-2.5 rounded-xl border border-[rgba(17,17,19,0.08)] bg-[#FAFAF8] p-4">
                  <div className="flex items-center justify-between text-[12px]">
                    <span className="text-[#5C5C62]">{t.bento.cards.cache.firstOpen}</span>
                    <span className="font-mono text-[#5C5C62]">archive.tar.gz (1.8 GB)</span>
                  </div>
                  <div className="h-2 w-full rounded-full bg-[rgba(17,17,19,0.08)]">
                    <div className="h-full w-[78%] rounded-full bg-[#5C5C62]/45" />
                  </div>
                  <div className="flex items-center justify-between pt-1 text-[12px]">
                    <span className="font-medium text-[#111113]">{t.bento.cards.cache.secondOpen}</span>
                    <span className="font-mono font-semibold text-[#0071E3]">&lt; 0.1s</span>
                  </div>
                  <div className="h-2 w-full rounded-full bg-[rgba(17,17,19,0.08)]">
                    <div className="h-full w-[8%] rounded-full bg-[#0071E3]" />
                  </div>
                </div>
              </div>

              {/* Card 4: Legacy ZIP Filename Repair (6 cols) */}
              <div className="flex flex-col justify-between rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-7 lg:col-span-6">
                <div>
                  <div className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#0071E3]">
                    <Sparkles className="h-3.5 w-3.5" />
                    <span>{t.bento.cards.encoding.eyebrow}</span>
                  </div>
                  <h3 className="mt-2.5 text-[21px] font-semibold tracking-[-0.02em] text-[#111113]">
                    {t.bento.cards.encoding.title}
                  </h3>
                  <p className="mt-2.5 text-[14.5px] leading-[1.6] text-[#5C5C62]">
                    {t.bento.cards.encoding.body}
                  </p>
                </div>

                <div className="mt-7 grid grid-cols-1 gap-2.5 rounded-xl border border-[rgba(17,17,19,0.08)] bg-[#FAFAF8] p-4 sm:grid-cols-2">
                  <div className="rounded-lg border border-[rgba(17,17,19,0.07)] bg-white px-3.5 py-2.5">
                    <div className="text-[11px] text-[#5C5C62]">{t.bento.cards.encoding.beforeLabel}</div>
                    <div className="mt-1 font-mono text-[12.5px] text-[#5C5C62] line-through decoration-[#5C5C62]/40">
                      ÏîÄ¿ÎÄ¼þ_2026.zip
                    </div>
                  </div>
                  <div className="rounded-lg border border-[#0071E3]/25 bg-white px-3.5 py-2.5">
                    <div className="flex items-center gap-1 text-[11px] font-medium text-[#0071E3]">
                      <Check className="h-3 w-3" strokeWidth={2.5} />
                      <span>{t.bento.cards.encoding.afterLabel}</span>
                    </div>
                    <div className="mt-1 font-mono text-[12.5px] font-medium text-[#111113]">
                      项目文件_2026.zip
                    </div>
                  </div>
                </div>
              </div>

              {/* Card 5: Full-Width Security, Split Volumes & Apple Archive */}
              <div className="flex flex-col justify-between gap-6 rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-7 lg:col-span-12 lg:flex-row lg:items-center">
                <div className="max-w-[620px]">
                  <div className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#0071E3]">
                    <Lock className="h-3.5 w-3.5" />
                    <span>{t.bento.cards.security.eyebrow}</span>
                  </div>
                  <h3 className="mt-2.5 text-[22px] font-semibold tracking-[-0.02em] text-[#111113]">
                    {t.bento.cards.security.title}
                  </h3>
                  <p className="mt-2.5 text-[14.5px] leading-[1.6] text-[#5C5C62]">
                    {t.bento.cards.security.body}
                  </p>
                </div>

                <div className="flex flex-wrap gap-2 lg:max-w-[380px] lg:justify-end">
                  {t.bento.cards.security.tags.map((tag) => (
                    <span
                      key={tag}
                      className="inline-flex items-center gap-1.5 rounded-full border border-[rgba(17,17,19,0.09)] bg-[#F3F3F1] px-3.5 py-1.5 text-[12.5px] font-medium text-[#111113]"
                    >
                      <KeyRound className="h-3 w-3 text-[#0071E3]" />
                      <span>{tag}</span>
                    </span>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* Interactive Format Matrix */}
        <section id="formats" className="border-t border-[rgba(17,17,19,0.08)] py-20 sm:py-24">
          <div className="mx-auto max-w-[1120px] px-5 sm:px-8">
            <div className="flex flex-col gap-6 md:flex-row md:items-end md:justify-between">
              <div className="max-w-[620px]">
                <p className="text-[12.5px] font-semibold uppercase tracking-[0.06em] text-[#0071E3]">
                  {t.formatsSection.eyebrow}
                </p>
                <h2 className="mt-2.5 text-[28px] font-semibold tracking-[-0.025em] leading-[1.15] text-[#111113] sm:text-[38px]">
                  {t.formatsSection.title}
                </h2>
                <p className="mt-3 text-[15.5px] leading-[1.6] text-[#5C5C62]">
                  {t.formatsSection.subtitle}
                </p>
              </div>

              <div
                role="tablist"
                aria-label="Filter formats"
                className="inline-flex flex-wrap gap-1 rounded-2xl border border-[rgba(17,17,19,0.08)] bg-[#F3F3F1] p-1 self-start"
              >
                {(
                  [
                    { id: 'all', label: t.formatsSection.tabs.all },
                    { id: 'writable', label: t.formatsSection.tabs.writable },
                    { id: 'readOnly', label: t.formatsSection.tabs.readOnly },
                    { id: 'packages', label: t.formatsSection.tabs.packages },
                  ] as const
                ).map((tab) => {
                  const active = activeFormatTab === tab.id;
                  return (
                    <button
                      key={tab.id}
                      type="button"
                      role="tab"
                      aria-selected={active}
                      onClick={() => setActiveFormatTab(tab.id)}
                      className={`rounded-full px-3.5 py-1.5 text-[12.5px] font-medium transition-all ${
                        active
                          ? 'bg-white text-[#111113] shadow-[0_1px_2px_rgba(17,17,19,0.08)]'
                          : 'text-[#5C5C62] hover:text-[#111113]'
                      }`}
                    >
                      {tab.label}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="mt-10 grid grid-cols-1 gap-3.5 sm:grid-cols-2 lg:grid-cols-4">
              {filteredFormats.map((item) => (
                <div
                  key={item.id}
                  className="flex flex-col justify-between rounded-xl border border-[rgba(17,17,19,0.08)] bg-white p-4 transition-colors hover:border-[rgba(17,17,19,0.16)]"
                >
                  <div>
                    <div className="flex items-start justify-between gap-2">
                      <span className="text-[16px] font-semibold tracking-[-0.015em] text-[#111113]">
                        {item.name}
                      </span>
                      <span
                        className={`shrink-0 rounded-full px-2 py-0.5 text-[10.5px] font-medium ${
                          item.writable
                            ? 'bg-[#0071E3]/10 text-[#0071E3]'
                            : 'bg-[#F3F3F1] text-[#5C5C62]'
                        }`}
                      >
                        {item.writable ? t.formatsSection.badgeWritable : t.formatsSection.badgeReadOnly}
                      </span>
                    </div>

                    <div className="mt-1 font-mono text-[11.5px] text-[#5C5C62]">
                      {item.extensions}
                    </div>

                    <p className="mt-2.5 text-[13px] leading-[1.55] text-[#5C5C62]">
                      {lang === 'zh' ? item.noteZh : item.noteEn}
                    </p>
                  </div>

                  {(item.supportsPassword || item.supportsSplit) && (
                    <div className="mt-3.5 flex flex-wrap gap-1.5 border-t border-[rgba(17,17,19,0.06)] pt-2.5">
                      {item.supportsPassword && (
                        <span className="rounded bg-[#FAFAF8] px-1.5 py-0.5 text-[10.5px] font-medium text-[#5C5C62] ring-1 ring-inset ring-[rgba(17,17,19,0.08)]">
                          {t.formatsSection.badgePassword}
                        </span>
                      )}
                      {item.supportsSplit && (
                        <span className="rounded bg-[#FAFAF8] px-1.5 py-0.5 text-[10.5px] font-medium text-[#5C5C62] ring-1 ring-inset ring-[rgba(17,17,19,0.08)]">
                          {t.formatsSection.badgeSplit}
                        </span>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Workflow Shortcuts & Craft Strip */}
        <section id="craft" className="border-t border-[rgba(17,17,19,0.08)] bg-white/60 py-20 sm:py-24">
          <div className="mx-auto max-w-[1120px] px-5 sm:px-8">
            <div className="max-w-[600px]">
              <p className="text-[12.5px] font-semibold uppercase tracking-[0.06em] text-[#0071E3]">
                {t.craft.eyebrow}
              </p>
              <h2 className="mt-2.5 text-[28px] font-semibold tracking-[-0.025em] leading-[1.15] text-[#111113] sm:text-[36px]">
                {t.craft.title}
              </h2>
            </div>

            <div className="mt-10 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
              {t.craft.items.map((item) => (
                <div
                  key={item.title}
                  className="flex flex-col justify-between rounded-2xl border border-[rgba(17,17,19,0.08)] bg-white p-6"
                >
                  <div>
                    <h3 className="text-[16px] font-semibold tracking-[-0.01em] text-[#111113]">
                      {item.title}
                    </h3>
                    <p className="mt-2.5 text-[13.5px] leading-[1.6] text-[#5C5C62]">{item.body}</p>
                  </div>

                  {item.keys && (
                    <div className="mt-5 flex flex-wrap gap-1.5 pt-2">
                      {item.keys.map((k) => (
                        <kbd key={k} className="keycap">
                          {k}
                        </kbd>
                      ))}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Calm Closing CTA */}
        <section className="border-t border-[rgba(17,17,19,0.08)] py-20 sm:py-24">
          <div className="mx-auto max-w-[680px] px-5 text-center sm:px-8">
            <img
              src="/images/app-icon.png"
              alt="BentoZip"
              width={72}
              height={72}
              className="mx-auto h-[72px] w-[72px] rounded-[18px] shadow-[0_8px_24px_rgba(17,17,19,0.12)]"
            />
            <h2 className="mt-6 text-[30px] font-semibold tracking-[-0.025em] leading-[1.15] text-[#111113] sm:text-[40px]">
              {t.closing.title}
            </h2>
            <p className="mx-auto mt-3.5 max-w-[520px] text-[16px] leading-[1.6] text-[#5C5C62]">
              {t.closing.subtitle}
            </p>
            <div className="mt-7 flex justify-center">
              <a
                href={RELEASE_URL}
                target="_blank"
                rel="noreferrer"
                className="inline-flex h-11 items-center gap-2 rounded-full bg-[#0071E3] px-7 text-[14.5px] font-medium text-white shadow-[0_2px_10px_rgba(0,113,227,0.22)] transition-all hover:bg-[#0077ED]"
              >
                <ArrowDownToLine className="h-4 w-4" strokeWidth={2} />
                <span>{t.closing.cta}</span>
              </a>
            </div>
            <p className="mt-3.5 text-[12.5px] text-[#5C5C62]">{t.closing.meta}</p>
          </div>
        </section>
      </main>

      {/* Minimal Footer */}
      <footer className="border-t border-[rgba(17,17,19,0.08)] bg-[#FAFAF8] py-8">
        <div className="mx-auto flex max-w-[1120px] flex-col items-center justify-between gap-4 px-5 text-[13px] text-[#5C5C62] sm:flex-row sm:px-8">
          <div className="flex items-center gap-2.5">
            <img src="/images/app-icon.png" alt="" width={20} height={20} className="h-5 w-5 rounded-[5px]" />
            <span className="font-medium text-[#111113]">BentoZip</span>
            <span className="text-[#5C5C62]">/</span>
            <span>{t.footer.tagline}</span>
          </div>

          <div className="flex items-center gap-5">
            <a
              href={RELEASE_URL}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-[#111113]"
            >
              {t.footer.releases}
            </a>
            <a
              href={REPO_URL}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-[#111113]"
            >
              {t.footer.license}
            </a>
            <button
              type="button"
              onClick={() => setLang(lang === 'en' ? 'zh' : 'en')}
              className="transition-colors hover:text-[#111113]"
            >
              {lang === 'en' ? '中文' : 'English'}
            </button>
            <span>{t.footer.copyright}</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
