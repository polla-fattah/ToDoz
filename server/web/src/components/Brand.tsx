import { Check } from 'lucide-react';

/** The NoteDo mark: a check on the brand gradient. */
export function BrandMark() {
  return (
    <span className="brand-mark" aria-hidden="true">
      <Check size={17} strokeWidth={3.2} />
    </span>
  );
}
