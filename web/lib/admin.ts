// User-management helpers for the admin console.
//
// Creating a user requires us to *not* replace the admin's current session,
// which the Firebase Web SDK would normally do via createUserWithEmailAndPassword.
// We solve that by spinning up a secondary FirebaseApp, doing the create against
// its Auth instance, then signing it out and deleting the app.

import { initializeApp, deleteApp, FirebaseOptions } from "firebase/app";
import { getAuth, createUserWithEmailAndPassword, sendPasswordResetEmail, updateProfile, signOut } from "firebase/auth";
import { ref, set, update, get } from "firebase/database";
import { auth, db } from "./firebase";

const firebaseConfig: FirebaseOptions = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY!,
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN!,
  databaseURL: process.env.NEXT_PUBLIC_FIREBASE_DATABASE_URL!,
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID!,
  storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET!,
  messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID!,
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID!,
};

export interface CreateUserInput {
  email: string;
  password: string;
  displayName: string;
  deviceName?: string;
}

/// Creates a Firebase Auth user + an RTDB profile under /users/{uid}/info.
/// Keeps the admin's primary session intact by using a secondary app instance.
export async function createManagedUser(input: CreateUserInput): Promise<{ uid: string }> {
  const email = input.email.trim().toLowerCase();
  const password = input.password;
  const displayName = input.displayName.trim();
  if (!email || !password) throw new Error("Email and password are required");
  if (password.length < 6) throw new Error("Password must be at least 6 characters");

  const secondaryName = `bsafe-secondary-${Date.now()}`;
  const secondary = initializeApp(firebaseConfig, secondaryName);
  try {
    const sAuth = getAuth(secondary);
    const cred = await createUserWithEmailAndPassword(sAuth, email, password);
    const uid = cred.user.uid;
    if (displayName) {
      try { await updateProfile(cred.user, { displayName }); } catch { /* non-fatal */ }
    }

    // Profile node — matches the shape iOS's RemoteSyncService.registerDevice writes
    // so the admin device list (loadUsers) picks it up immediately.
    await set(ref(db, `users/${uid}/info`), {
      email,
      displayName: displayName || "",
      deviceName: input.deviceName?.trim() || "",
      isOnline: false,
      lastSeen: Date.now(),
      createdByAdmin: auth.currentUser?.uid ?? null,
      createdAt: Date.now(),
    });

    await signOut(sAuth);
    return { uid };
  } finally {
    await deleteApp(secondary);
  }
}

export interface ManagedUserUpdate {
  displayName?: string;
  deviceName?: string;
}

export async function updateManagedUser(uid: string, updates: ManagedUserUpdate): Promise<void> {
  const patch: Record<string, string> = {};
  if (updates.displayName !== undefined) patch.displayName = updates.displayName.trim();
  if (updates.deviceName !== undefined) patch.deviceName = updates.deviceName.trim();
  if (Object.keys(patch).length === 0) return;
  await update(ref(db, `users/${uid}/info`), patch);
}

/// Sends a Firebase Auth password-reset email to the user. The user has to
/// click the link, which is the only path the client SDK supports without
/// the Firebase Admin SDK (which would run on a Cloud Function).
export async function sendUserPasswordReset(email: string): Promise<void> {
  const trimmed = email.trim().toLowerCase();
  if (!trimmed) throw new Error("Email is required");
  await sendPasswordResetEmail(auth, trimmed);
}

/// Soft-delete: marks the profile but does NOT delete the Firebase Auth account
/// (that requires Admin SDK). The device list filter skips deleted entries.
export async function disableManagedUser(uid: string): Promise<void> {
  await update(ref(db, `users/${uid}/info`), {
    disabled: true,
    disabledAt: Date.now(),
  });
}

export async function emailExists(email: string): Promise<boolean> {
  // Search the /users tree by email. Not ideal at scale but fine for a
  // family-sized roster; matches how loadUsers already iterates.
  const snap = await get(ref(db, "users"));
  if (!snap.exists()) return false;
  let found = false;
  snap.forEach((child) => {
    const info = child.child("info").val() as { email?: string } | null;
    if (info?.email?.toLowerCase() === email.trim().toLowerCase()) {
      found = true;
      return true;
    }
    return false;
  });
  return found;
}
