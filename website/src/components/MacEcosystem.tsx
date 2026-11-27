import React, { useState } from 'react';
import { Check, Command, Copy, Eye, FolderSearch, MousePointerClick, Terminal } from 'lucide-react';

type IntegrationId = 'quicklook' | 'finder' | 'spotlight' | 'automation';

interface IntegrationSpec {
  id: IntegrationId;
  title: string;
  subtitle: string;
  badge: string;
  description: string;
  highlights: string[];
}

const INTEGRATIONS: IntegrationSpec[] = [
  {
    id: 'quicklook',
    title: 'Quick Look Extension',
    subtitle: 'Spacebar archive inspection in Finder',
    badge: 'BentoZipQuickLook.appex',
    description:
      'Press Space on any ZIP, 7z, TAR, RAR, Zstandard, DMG, or PKG in Finder. BentoZip renders a structured preview of contained folders, file counts, total size, and packed ratio before you ever launch the app.',
    highlights: [
      'Works directly from Finder with zero full extraction',
      'Displays nested folder structure and file count summary',
      'Supports password-protected container detection',
    ],
  },
  {
    id: 'finder',
    title: 'Finder Sync & Services',
    subtitle: 'Right-click context actions & toolbar button',
    badge: 'BentoZipFinderExtension.appex',
    description:
      'Compress selected folders or extract archives directly from Finder’s context menu, Finder toolbar, or the macOS Services menu—verified over per-user IPC tokens.',
    highlights: [
      'Compress with BentoZip on any file or folder selection',
      'Extract Here, Extract to Folder, or Browse in BentoZip',
      'Toolbar button + macOS Services integration across apps',
    ],
  },
  {
    id: 'spotlight',
    title: 'Spotlight Archive Importer',
    subtitle: 'Search files inside archives system-wide',
    badge: 'BentoZipSpotlight.mdimporter',
    description:
      'CoreSpotlight indexes entry paths and metadata inside your archives so Spotlight and Finder search locate buried source files, PDFs, or builds without manual unpacking.',
    highlights: [
      'Indexes internal file paths and archive summaries',
      'Runs sandboxed inside macOS Spotlight indexing',
      'Surfaces matching archives instantaneously in Finder search',
    ],
  },
  {
    id: 'automation',
    title: 'Shortcuts & bentozip CLI',
    subtitle: 'App Intents + POSIX CLI wrapper',
    badge: '/usr/local/bin/bentozip',
    description:
      'Build zero-click Apple Shortcuts workflows with four native App Intents, or install the bundled bentozip command-line wrapper from Settings for scripts and CI pipelines.',
    highlights: [
      'Shortcuts: Compress, Extract, List, and Test Archive intents',
      'CLI commands: open, list, extract, compress, and test',
      'Password, format, and compression level flags built in',
    ],
  },
];

const CLI_SNIPPET = `# Install via BentoZip Settings > General > Install CLI Tool
bentozip open Release-Kit-v2.4.zip
bentozip list Design-System-v4.2.tar.gz
bentozip extract Assets-Backup.7z ./out --password "$ARCHIVE_PW"
bentozip compress dist.tar.zst ./build --format tar.zst --level best
bentozip test Release-Kit-v2.4.zip`;

export default function MacEcosystem() {
  const [activeId, setActiveId] = useState<IntegrationId>('quicklook');
  const [copied, setCopied] = useState(false);

  const active = INTEGRATIONS.find((item) => item.id === activeId) ?? INTEGRATIONS[0];

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(CLI_SNIPPET);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      // Clipboard unavailable
    }
  };

  return (
    <div className="mt-12 grid grid-cols-1 lg:grid-cols-12 gap-6 items-stretch">
      {/* Left Selector Column */}
      <div className="lg:col-span-5 min-w-0 flex flex-col gap-2.5" role="tablist" aria-label="macOS Integrations">
        {INTEGRATIONS.map((item) => {
          const isActive = item.id === activeId;
          const Icon =
            item.id === 'quicklook'
              ? Eye
              : item.id === 'finder'
                ? MousePointerClick
                : item.id === 'spotlight'
                  ? FolderSearch
                  : Terminal;

          return (
            <button
              key={item.id}
              type="button"
              role="tab"
              aria-selected={isActive}
              onClick={() => setActiveId(item.id)}
              className={`text-left p-4 sm:p-5 rounded-2xl border transition-all cursor-pointer ${
                isActive
                  ? 'bg-[#16181E] border-[#0A84FF]/60 shadow-[0_12px_30px_rgba(0,0,0,0.35)]'
                  : 'bg-[#101216] border-white/[0.08] hover:border-white/[0.18] hover:bg-[#14161C]'
              }`}
            >
              <div className="flex items-start gap-3.5">
                <div
                  className={`w-9 h-9 rounded-xl flex items-center justify-center shrink-0 border ${
                    isActive
                      ? 'bg-[#0A84FF]/15 border-[#0A84FF]/40 text-[#409CFF]'
                      : 'bg-white/[0.04] border-white/[0.08] text-[#98989D]'
                  }`}
                >
                  <Icon className="w-4 h-4" />
                </div>
                <div className="min-w-0">
                  <div className="text-[15px] font-semibold text-white tracking-[-0.01em]">
                    {item.title}
                  </div>
                  <div className="mt-0.5 text-[13px] text-[#8E8E93]">
                    {item.subtitle}
                  </div>
                </div>
              </div>
            </button>
          );
        })}
      </div>

      {/* Right Detail & Live Simulation Surface */}
      <div className="lg:col-span-7 min-w-0 rounded-2xl bg-[#12141A] border border-white/[0.1] p-6 sm:p-8 flex flex-col justify-between">
        <div>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="font-mono text-[12px] px-2.5 py-1 rounded-md bg-white/[0.06] border border-white/[0.08] text-[#A1A1A6]">
              {active.badge}
            </span>
            <span className="text-[12px] text-[#6E6E73] font-mono">
              macOS System Extension
            </span>
          </div>

          <h3 className="mt-5 text-[24px] font-semibold text-white tracking-[-0.02em]">
            {active.title}
          </h3>
          <p className="mt-2.5 text-[15.5px] leading-[1.6] text-[#A1A1A6]">
            {active.description}
          </p>

          <ul className="mt-5 space-y-2.5">
            {active.highlights.map((bullet) => (
              <li key={bullet} className="flex items-start gap-2.5 text-[14px] text-[#D1D1D6]">
                <Check className="w-4 h-4 text-[#30D158] shrink-0 mt-0.5" />
                <span>{bullet}</span>
              </li>
            ))}
          </ul>
        </div>

        {/* Contextual Native Preview Widget */}
        <div className="mt-7 rounded-xl bg-[#0A0B0E] border border-white/[0.09] overflow-hidden">
          {active.id === 'quicklook' && (
            <div className="p-4 sm:p-5 font-mono text-[12.5px]">
              <div className="flex items-center justify-between pb-3 border-b border-white/[0.08] text-[#8E8E93]">
                <span className="text-white font-semibold">Release-Kit-v2.4.zip</span>
                <span>Spacebar Quick Look · 428 items · 54% saved</span>
              </div>
              <div className="mt-3 space-y-1.5 text-[#D1D1D6]">
                <div className="flex justify-between">
                  <span>▸ Brand-Assets/</span>
                  <span className="text-[#8E8E93]">1.3 MB</span>
                </div>
                <div className="flex justify-between pl-4">
                  <span>Brand-Guidelines.pdf</span>
                  <span className="text-[#8E8E93]">891 KB</span>
                </div>
                <div className="flex justify-between">
                  <span>▸ Components/</span>
                  <span className="text-[#8E8E93]">85 KB</span>
                </div>
                <div className="flex justify-between">
                  <span>CHANGELOG.md</span>
                  <span className="text-[#8E8E93]">17 KB</span>
                </div>
              </div>
            </div>
          )}

          {active.id === 'finder' && (
            <div className="p-4 sm:p-5">
              <div className="text-[11.5px] font-mono uppercase tracking-wider text-[#6E6E73] mb-3">
                Finder Context Menu &amp; Services
              </div>
              <div className="max-w-[300px] rounded-xl bg-[#1C1E26] border border-white/[0.12] p-1.5 shadow-xl text-[13px]">
                <div className="px-3 py-1.5 rounded-lg bg-[#0A84FF] text-white font-medium flex items-center justify-between">
                  <span>Compress with BentoZip</span>
                  <span className="text-[11px] opacity-80">Service</span>
                </div>
                <div className="px-3 py-1.5 rounded-lg text-[#E5E5EA] flex items-center justify-between">
                  <span>Extract Here</span>
                  <span className="text-[11px] text-[#8E8E93]">Finder Sync</span>
                </div>
                <div className="px-3 py-1.5 rounded-lg text-[#E5E5EA] flex items-center justify-between">
                  <span>Extract to Folder with BentoZip</span>
                </div>
                <div className="px-3 py-1.5 rounded-lg text-[#E5E5EA]">
                  Browse in BentoZip
                </div>
              </div>
            </div>
          )}

          {active.id === 'spotlight' && (
            <div className="p-4 sm:p-5">
              <div className="flex items-center gap-2.5 px-3.5 py-2.5 rounded-lg bg-[#16181F] border border-white/[0.1] text-[13.5px] text-white">
                <FolderSearch className="w-4 h-4 text-[#0A84FF]" />
                <span>DesignTokens.json</span>
                <span className="ml-auto font-mono text-[11.5px] text-[#6E6E73]">⌘Space</span>
              </div>
              <div className="mt-3 px-1 flex items-center justify-between text-[12.5px]">
                <div>
                  <div className="text-white font-medium">Design-System-v4.2.tar.gz</div>
                  <div className="text-[#8E8E93] font-mono text-[11.5px]">
                    Matched internal entry: Foundations/DesignTokens.json
                  </div>
                </div>
                <span className="font-mono text-[11.5px] text-[#30D158]">Indexed</span>
              </div>
            </div>
          )}

          {active.id === 'automation' && (
            <div>
              <div className="flex items-center justify-between px-4 py-2.5 border-b border-white/[0.08] bg-white/[0.02]">
                <div className="flex items-center gap-2 text-[12px] font-mono text-[#A1A1A6]">
                  <Command className="w-3.5 h-3.5 text-[#0A84FF]" />
                  <span>bentozip CLI · Apple Shortcuts AppIntents</span>
                </div>
                <button
                  type="button"
                  onClick={handleCopy}
                  className="inline-flex items-center gap-1.5 text-[12px] font-mono text-[#A1A1A6] hover:text-white transition-colors cursor-pointer"
                >
                  {copied ? (
                    <>
                      <Check className="w-3.5 h-3.5 text-[#30D158]" />
                      <span className="text-[#30D158]">Copied</span>
                    </>
                  ) : (
                    <>
                      <Copy className="w-3.5 h-3.5" />
                      <span>Copy</span>
                    </>
                  )}
                </button>
              </div>
              <pre className="p-4 text-[12px] leading-[1.65] text-[#D1D1D6] overflow-x-auto m-0">
                <code>{CLI_SNIPPET}</code>
              </pre>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
