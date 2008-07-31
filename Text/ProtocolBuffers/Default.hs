module Text.ProtocolBuffers.Default(Default(..)) where

import Text.ProtocolBuffers.Basic
import Text.ProtocolBuffers.Mergeable (Mergeable(mergeEmpty))

-- Anything with an "mempty / mergeEmpty" can be a trivial "Mondad / Mergeable"
--
-- So it makes some sense to make the default defaultValue be this empty value
class Mergeable a => Default a where
  defaultValue :: a
  defaultValue = mergeEmpty

instance Default a => Default (Maybe a) where defaultValue = Just defaultValue

-- Take the mergeEmpty as the defaultValue
instance Default (Seq a) where
instance Default Bool where
instance Default ByteString where
instance Default Double where
instance Default Float where
instance Default Int32 where
instance Default Int64 where
instance Default Word32 where
instance Default Word64 where