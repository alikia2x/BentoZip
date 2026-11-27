import React, { useMemo, useState } from 'react';
import { Search, X } from 'lucide-react';
import {
  ARCHIVE_FORMAT_SPECS,
  FORMAT_CATEGORIES,
  type FormatCapability,
  type FormatCategoryId,
} from '../data/formats';

const CAPABILITY_STYLES: Record<FormatCapability, string> = {
  Create: 'bg-[#0071E3]/10 text-[#005BB5] ring-[#0071E3]/20',
  'In-Place Edit': 'bg-[#1D8F4E]/10 text-[#146C39] ring-[#1D8F4E]/20',
  'Rebuild Edit': 'bg-[#7A5AF8]/10 text-[#5939D6] ring-[#7A5AF8]/20',
  Encrypt: 'bg-[#B25E09]/10 text-[#8F4A04] ring-[#B25E09]/20',
  Split: 'bg-[#3A3A3C]/8 text-[#3A3A3C] ring-black/10',
  Extract: 'bg-[#F2F2F7] text-[#515154] ring-black/8',
};

export default function FormatMatrix() {
  const [selectedCategory, setSelectedCategory] = useState<FormatCategoryId | 'all'>('all');
  const [query, setQuery] = useState('');

  const categoryCounts = useMemo(() => {
    const counts: Record<string, number> = { all: ARCHIVE_FORMAT_SPECS.length };
    for (const fmt of ARCHIVE_FORMAT_SPECS) {
      counts[fmt.category] = (counts[fmt.category] ?? 0) + 1;
    }
    return counts;
  }, []);

  const filteredFormats = useMemo(() => {
    const q = query.trim().toLowerCase();
    return ARCHIVE_FORMAT_SPECS.filter((fmt) => {
      if (selectedCategory !== 'all' && fmt.category !== selectedCategory) {
        return false;
      }
      if (!q) return true;
      return (
        fmt.name.toLowerCase().includes(q) ||
        fmt.summary.toLowerCase().includes(q) ||
        fmt.extensions.some((ext) => ext.toLowerCase().includes(q)) ||
        fmt.capabilities.some((cap) => cap.toLowerCase().includes(q))
      );
    });
  }, [selectedCategory, query]);

  return (
    <div className="mt-10">
      {/* Controls Bar */}
      <div className="flex flex-col lg:flex-row lg:items-center justify-between gap-4 pb-6 border-b border-black/[0.08]">
        {/* Category Pills */}
        <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Filter formats by category">
          {FORMAT_CATEGORIES.map((cat) => {
            const active = selectedCategory === cat.id;
            return (
              <button
                key={cat.id}
                type="button"
                onClick={() => setSelectedCategory(cat.id)}
                className={`inline-flex items-center gap-2 px-3.5 py-2 rounded-full text-[13px] font-medium transition-all cursor-pointer ${
                  active
                    ? 'bg-[#1D1D1F] text-white shadow-sm'
                    : 'bg-[#F2F2F7] text-[#515154] hover:bg-[#E5E5EA] hover:text-[#1D1D1F]'
                }`}
              >
                <span>{cat.label}</span>
                <span
                  className={`font-mono text-[11px] tabular-nums ${
                    active ? 'text-white/70' : 'text-[#86868B]'
                  }`}
                >
                  {categoryCounts[cat.id] ?? 0}
                </span>
              </button>
            );
          })}
        </div>

        {/* Search Input */}
        <div className="relative w-full lg:w-[270px] shrink-0">
          <Search className="w-4 h-4 text-[#86868B] absolute left-3.5 top-1/2 -translate-y-1/2 pointer-events-none" />
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Filter by extension or format (e.g. .zst, dmg)"
            aria-label="Filter archive formats"
            className="w-full h-10 pl-10 pr-9 rounded-xl bg-[#F5F5F7] border border-black/[0.08] text-[13.5px] text-[#1D1D1F] placeholder:text-[#86868B] focus:outline-none focus:bg-white focus:border-[#0071E3] focus:ring-2 focus:ring-[#0071E3]/15 transition-all"
          />
          {query && (
            <button
              type="button"
              onClick={() => setQuery('')}
              aria-label="Clear format filter"
              className="absolute right-2.5 top-1/2 -translate-y-1/2 p-1 rounded-md text-[#86868B] hover:text-[#1D1D1F] cursor-pointer"
            >
              <X className="w-3.5 h-3.5" />
            </button>
          )}
        </div>
      </div>

      {/* Results */}
      {filteredFormats.length === 0 ? (
        <div className="py-16 text-center">
          <p className="text-[15px] text-[#515154]">
            No formats matched <span className="font-mono text-[#1D1D1F]">"{query}"</span>.
          </p>
          <button
            type="button"
            onClick={() => {
              setQuery('');
              setSelectedCategory('all');
            }}
            className="mt-3 text-[13.5px] font-medium text-[#0071E3] hover:underline cursor-pointer"
          >
            Reset filters
          </button>
        </div>
      ) : (
        <div className="mt-6 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {filteredFormats.map((fmt) => (
            <article
              key={fmt.id}
              className="rounded-2xl bg-[#FBFBFD] border border-black/[0.08] p-5 flex flex-col justify-between hover:border-black/[0.16] transition-colors"
            >
              <div>
                <div className="flex items-start justify-between gap-3">
                  <h3 className="text-[16px] font-semibold text-[#1D1D1F] tracking-[-0.015em]">
                    {fmt.name}
                  </h3>
                  <div className="flex flex-wrap justify-end gap-1">
                    {fmt.extensions.map((ext) => (
                      <span
                        key={ext}
                        className="font-mono text-[11.5px] font-medium text-[#1D1D1F] bg-white px-2 py-0.5 rounded-md ring-1 ring-black/[0.08]"
                      >
                        {ext}
                      </span>
                    ))}
                  </div>
                </div>

                <p className="mt-2.5 text-[13.5px] leading-[1.55] text-[#515154]">
                  {fmt.summary}
                </p>
              </div>

              <div className="mt-4 pt-3.5 border-t border-black/[0.06] flex flex-wrap gap-1.5">
                {fmt.capabilities.map((cap) => (
                  <span
                    key={cap}
                    className={`inline-flex items-center px-2 py-0.5 rounded-md text-[11px] font-medium ring-1 ${CAPABILITY_STYLES[cap]}`}
                  >
                    {cap}
                  </span>
                ))}
              </div>
            </article>
          ))}
        </div>
      )}
    </div>
  );
}
