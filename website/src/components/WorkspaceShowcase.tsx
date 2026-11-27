import React, { useState } from 'react';
import { FolderTree, Gauge, KeyRound, SlidersHorizontal, Sun, Moon } from 'lucide-react';

interface ShowcaseTab {
  id: 'browser' | 'studio' | 'tasks' | 'vault';
  label: string;
  shortLabel: string;
  headline: string;
  description: string;
  image: string;
  altImage?: string;
  imageAlt: string;
  secondaryImage?: string;
  secondaryImageAlt?: string;
  specs: { label: string; detail: string }[];
}

const SHOWCASE_TABS: ShowcaseTab[] = [
  {
    id: 'browser',
    label: 'Finder Browser & Inspector',
    shortLabel: 'Browser',
    headline: 'Inspect before you unpack.',
    description:
      'Open archives directly inside a native NSOutlineView list or adaptive icon grid. Drill down into nested archives, preview images or text inline, hit Space for Quick Look, or drag single files onto your Desktop via file promises.',
    image: '/images/hero-browse.png',
    imageAlt: 'BentoZip browsing Design-System-v4.2.tar.gz with Finder hierarchy and Info inspector',
    specs: [
      {
        label: 'Nested Drill-Down & Save-Back',
        detail: 'Step into ZIP/TAR containers inside archives and save external edits back automatically.',
      },
      {
        label: 'Live Columns & Toolbar Search',
        detail: 'Toggle Size, Packed, Ratio, CRC32, Date, and Kind with instant tree filtering.',
      },
      {
        label: 'Lazy Drag-Out Extraction',
        detail: 'NSFilePromiseProvider extracts only the dragged file without unpacking the archive.',
      },
    ],
  },
  {
    id: 'studio',
    label: 'Compression Studio & Presets',
    shortLabel: 'Compression',
    headline: 'Precision packing in a single drawer.',
    description:
      'Stage folders, apply reusable compression presets, pick ZIP (AES-256 / ZipCrypto) or 7z with header encryption, split oversized bundles into 10 MB–4 GB volumes, and strip macOS clutter automatically.',
    image: '/images/workspace-presets-dark.png',
    altImage: '/images/feature-compress.png',
    imageAlt: 'BentoZip compression studio showing Presets, AES-256 password, split volumes, and exclusion rules',
    specs: [
      {
        label: 'Reusable Presets & Batch Mode',
        detail: 'Save format, level, and split profiles or compress multiple staged items separately.',
      },
      {
        label: 'Header-Encrypted 7z & AES-256 ZIP',
        detail: 'Hide filenames until unlocked or generate strong passwords right inside the inspector.',
      },
      {
        label: 'Clean Mac Archives',
        detail: 'Filter .DS_Store, __MACOSX, and custom glob patterns while controlling symlink behavior.',
      },
    ],
  },
  {
    id: 'tasks',
    label: 'Background Tasks & Cache',
    shortLabel: 'Tasks',
    headline: 'Heavy jobs stay out of your way.',
    description:
      'Long compressions, multi-gigabyte extractions, and checksum builds run concurrently inside a decoupled Tasks window with live MB/s throughput, ETA, and compression ratio telemetry.',
    image: '/images/feature-tasks-dark.png',
    imageAlt: 'BentoZip floating dark-mode Tasks window displaying 142.6 MB/s live compression telemetry',
    specs: [
      {
        label: 'Non-Blocking Multi-Window Queue',
        detail: 'Keep browsing or opening other documents while transfers stack cleanly in Tasks.',
      },
      {
        label: 'Persistent .tar.* Disk Cache',
        detail: 'Caches unwrapped .tar streams under ~/Library/Caches (512 MB–4 GB LRU) for instant re-open.',
      },
      {
        label: 'Dedicated Interactive Worker',
        detail: 'Persistent bento7z --server socket keeps UI listings responsive under heavy I/O.',
      },
    ],
  },
  {
    id: 'vault',
    label: 'Touch ID Vault & Presets',
    shortLabel: 'Vault',
    headline: 'Stored in macOS Keychain, locked with Touch ID.',
    description:
      'Save trusted archive passwords in the Keychain Vault and unlock encrypted downloads automatically after Touch ID or macOS password verification—alongside custom presets and default format registration.',
    image: '/images/settings-vault-dark.png',
    imageAlt: 'BentoZip Keychain Password Vault locked with Touch ID',
    secondaryImage: '/images/settings-presets-dark.png',
    secondaryImageAlt: 'BentoZip Settings Presets editor showing Clean ZIP and Encrypted 7z profiles',
    specs: [
      {
        label: 'Keychain-Backed Password Vault',
        detail: 'Protected by LocalAuthentication (Touch ID) with optional auto-try on encrypted archives.',
      },
      {
        label: 'One-Click Default Handlers',
        detail: 'Claim .zip, .7z, .rar, .tar.*, .zst, and .aar right from Formats settings.',
      },
      {
        label: 'SHA-256 & MD5 Integrity',
        detail: 'Verify downloaded archives and inspect cryptographic digests off the main thread.',
      },
    ],
  },
];

const TAB_ICONS = {
  browser: FolderTree,
  studio: SlidersHorizontal,
  tasks: Gauge,
  vault: KeyRound,
} as const;

export default function WorkspaceShowcase() {
  const [activeId, setActiveId] = useState<ShowcaseTab['id']>('studio');
  const [studioLight, setStudioLight] = useState(false);

  const activeTab = SHOWCASE_TABS.find((t) => t.id === activeId) ?? SHOWCASE_TABS[0];
  const displayImage =
    activeTab.id === 'studio' && studioLight && activeTab.altImage ? activeTab.altImage : activeTab.image;

  return (
    <div className="mt-10">
      {/* Tab Strip */}
      <div
        role="tablist"
        aria-label="BentoZip Workspace Views"
        className="flex flex-wrap items-center justify-center gap-2 p-1.5 rounded-2xl bg-[#EBEBF0] border border-black/[0.06] max-w-fit mx-auto"
      >
        {SHOWCASE_TABS.map((tab) => {
          const Icon = TAB_ICONS[tab.id];
          const isActive = tab.id === activeId;
          return (
            <button
              key={tab.id}
              type="button"
              role="tab"
              aria-selected={isActive}
              aria-controls={`panel-${tab.id}`}
              id={`tab-${tab.id}`}
              onClick={() => setActiveId(tab.id)}
              className={`inline-flex items-center gap-2 px-4 py-2 rounded-xl text-[13.5px] font-medium tracking-[-0.01em] transition-all cursor-pointer ${
                isActive
                  ? 'bg-white text-[#1D1D1F] shadow-[0_2px_8px_rgba(0,0,0,0.08)] ring-1 ring-black/[0.05]'
                  : 'text-[#515154] hover:text-[#1D1D1F]'
              }`}
            >
              <Icon className="w-4 h-4 shrink-0" />
              <span className="hidden sm:inline">{tab.label}</span>
              <span className="sm:hidden">{tab.shortLabel}</span>
            </button>
          );
        })}
      </div>

      {/* Active Stage */}
      <div
        role="tabpanel"
        id={`panel-${activeTab.id}`}
        aria-labelledby={`tab-${activeTab.id}`}
        className="mt-8 rounded-[28px] bg-[#111216] border border-black/[0.08] p-5 sm:p-8 lg:p-10 shadow-[0_30px_80px_rgba(0,0,0,0.12)]"
      >
        <div className="flex flex-col md:flex-row md:items-end justify-between gap-5 pb-7 border-b border-white/[0.08]">
          <div className="max-w-[660px]">
            <h3 className="text-[24px] sm:text-[30px] font-semibold tracking-[-0.025em] text-white leading-[1.15]">
              {activeTab.headline}
            </h3>
            <p className="mt-2.5 text-[15.5px] leading-[1.6] text-[#A1A1A6]">
              {activeTab.description}
            </p>
          </div>

          {activeTab.altImage && (
            <div className="inline-flex items-center gap-1 p-1 rounded-lg bg-white/[0.06] border border-white/[0.08] self-start md:self-end shrink-0">
              <button
                type="button"
                onClick={() => setStudioLight(false)}
                className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-[12px] font-medium transition-colors cursor-pointer ${
                  !studioLight ? 'bg-white/[0.14] text-white' : 'text-[#8E8E93] hover:text-white'
                }`}
              >
                <Moon className="w-3.5 h-3.5" />
                <span>Dark</span>
              </button>
              <button
                type="button"
                onClick={() => setStudioLight(true)}
                className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-[12px] font-medium transition-colors cursor-pointer ${
                  studioLight ? 'bg-white/[0.14] text-white' : 'text-[#8E8E93] hover:text-white'
                }`}
              >
                <Sun className="w-3.5 h-3.5" />
                <span>Light</span>
              </button>
            </div>
          )}
        </div>

        {/* Visual Frame */}
        <div className="mt-7">
          {activeTab.secondaryImage ? (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6 items-start">
              <div className="rounded-[18px] overflow-hidden border border-white/[0.1] bg-[#1A1B20] shadow-[0_20px_50px_rgba(0,0,0,0.45)]">
                <img
                  src={activeTab.image}
                  alt={activeTab.imageAlt}
                  loading="lazy"
                  className="w-full h-auto block"
                />
              </div>
              <div className="rounded-[18px] overflow-hidden border border-white/[0.1] bg-[#1A1B20] shadow-[0_20px_50px_rgba(0,0,0,0.45)]">
                <img
                  src={activeTab.secondaryImage}
                  alt={activeTab.secondaryImageAlt ?? ''}
                  loading="lazy"
                  className="w-full h-auto block"
                />
              </div>
            </div>
          ) : (
            <div className="rounded-[20px] overflow-hidden border border-white/[0.1] bg-[#0B0C0F] shadow-[0_24px_64px_rgba(0,0,0,0.5)]">
              <img
                src={displayImage}
                alt={activeTab.imageAlt}
                loading="lazy"
                className="w-full h-auto block"
              />
            </div>
          )}
        </div>

        {/* Bottom Spec Strip */}
        <div className="mt-7 pt-6 border-t border-white/[0.08] grid grid-cols-1 md:grid-cols-3 gap-6">
          {activeTab.specs.map((spec) => (
            <div key={spec.label}>
              <h4 className="text-[14px] font-semibold text-white tracking-[-0.01em]">
                {spec.label}
              </h4>
              <p className="mt-1.5 text-[13.5px] leading-[1.55] text-[#98989D]">
                {spec.detail}
              </p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
