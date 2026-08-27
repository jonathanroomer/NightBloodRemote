/** The two deliberately different faces that consume the same truthful state. */
export const FACE_SKINS = ["nightblood", "marshmallow"] as const;

export type FaceSkin = (typeof FACE_SKINS)[number];

export const DEFAULT_FACE_SKIN: FaceSkin = "nightblood";
export const FACE_SKIN_STORAGE_KEY = "nightblood.face.skin";
export const FACE_SKIN_CHANGED_EVENT = "nightblood-face-skin-changed";

export function parseFaceSkin(value: unknown): FaceSkin | null {
  return value === "nightblood" || value === "marshmallow" ? value : null;
}

export function readFaceSkin(storage?: Pick<Storage, "getItem"> | null): FaceSkin {
  if (!storage) return DEFAULT_FACE_SKIN;
  try {
    return parseFaceSkin(storage.getItem(FACE_SKIN_STORAGE_KEY)) ?? DEFAULT_FACE_SKIN;
  } catch {
    return DEFAULT_FACE_SKIN;
  }
}

export function writeFaceSkin(
  skin: FaceSkin,
  storage?: Pick<Storage, "setItem"> | null,
): void {
  if (!storage) return;
  try {
    storage.setItem(FACE_SKIN_STORAGE_KEY, skin);
  } catch {
    // A locked-down kiosk still works; it simply forgets the choice.
  }
}

export function otherFaceSkin(skin: FaceSkin): FaceSkin {
  return skin === "nightblood" ? "marshmallow" : "nightblood";
}
