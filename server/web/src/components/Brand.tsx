import markUrl from '../assets/todoz_mark.png';

/** The ToDoz mark: official squircle icon mark. */
export function BrandMark({ size = 26 }: { size?: number }) {
  return (
    <img
      src={markUrl}
      alt="ToDoz"
      className="brand-mark-img"
      width={size}
      height={size}
      style={{ display: 'inline-block', verticalAlign: 'middle', objectFit: 'contain' }}
    />
  );
}
