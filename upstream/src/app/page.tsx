import { DesktopWorkspace } from '@/components/desktop/desktop-workspace';
import './desktop.css';

export default function HomePage() {
  return (
    <>
      <h1 className="sr-only">万能AI播放器</h1>
      <DesktopWorkspace />
    </>
  );
}
