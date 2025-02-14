use dep::std::hash::pedersen;
use dep::aztec::note::note_interface::NoteInterface;
use dep::aztec::note::note_header::NoteHeader;
use dep::aztec::oracle::get_secret_key::get_secret_key;
use dep::aztec::oracle::get_public_key::get_public_key;
use dep::aztec::note::utils::compute_siloed_note_hash;

global PUBLIC_KEY_NOTE_LEN: Field = 3;

// Stores a public key composed of two fields
// TODO: Do we need to include a nonce, in case we want to read/nullify/recreate with the same pubkey value?
struct PublicKeyNote {
    x: Field,
    y: Field,
    owner: Field, // We store the owner address only to get the secret key to compute the nullifier
    header: NoteHeader,
}

impl PublicKeyNote {
    fn new(x: Field, y: Field, owner: Field) -> Self {
        PublicKeyNote {
            x,
            y,
            owner,
            header: NoteHeader::empty(),
        }
    }

    // Serialise the note as 3 fields
    fn serialise(self) -> [Field; PUBLIC_KEY_NOTE_LEN] {
        [self.x, self.y, self.owner]
    }

    fn compute_nullifier(self) -> Field {
        let siloed_note_hash = compute_siloed_note_hash(PublicKeyNoteInterface, self);
        let owner_nullifying_public_key = get_public_key(self.owner);
        let secret = get_secret_key(owner_nullifying_public_key);
        dep::std::hash::pedersen([
            siloed_note_hash,
            secret,
        ])[0]
    }

    fn set_header(mut self: Self, header: NoteHeader) -> Self {
        self.header = header;
        self
    }

    fn dummy() -> Self {
        PublicKeyNote {
            x: 0,
            y: 0,
            owner: 0,
            header: NoteHeader::empty(),
        }
    }

    fn is_dummy(self) -> bool {
        (self.x == 0) & (self.y == 0) & (self.owner == 0)
    }
}

fn deserialise(preimage: [Field; PUBLIC_KEY_NOTE_LEN]) -> PublicKeyNote {
    PublicKeyNote {
        x: preimage[0],
        y: preimage[1],
        owner: preimage[2],
        header: NoteHeader::empty(),
    }
}

fn serialise(note: PublicKeyNote) -> [Field; PUBLIC_KEY_NOTE_LEN] {
    note.serialise()
}

fn compute_note_hash(note: PublicKeyNote) -> Field {
    dep::std::hash::pedersen(note.serialise())[0]
}

fn compute_nullifier(note: PublicKeyNote) -> Field {
    note.compute_nullifier()
}

fn dummy() -> PublicKeyNote {
    PublicKeyNote::dummy()
}

fn is_dummy(note: PublicKeyNote) -> bool {
    note.is_dummy()
}

fn get_header(note: PublicKeyNote) -> NoteHeader {
    note.header
}

fn set_header(note: PublicKeyNote, header: NoteHeader) -> PublicKeyNote {
    note.set_header(header)
}

global PublicKeyNoteInterface = NoteInterface {
    deserialise,
    serialise,
    compute_note_hash,
    compute_nullifier,
    dummy,
    is_dummy,
    get_header,
    set_header,
};
