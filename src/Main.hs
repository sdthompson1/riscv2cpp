-- MODULE:
--   Main
--
-- PURPOSE:
--   Main Program for Risc2cpp
--
-- AUTHOR:
--   Stephen Thompson <stephen@solarflare.org.uk>
--
-- CREATED:
--   15-Oct-2010 (original version - Mips2cs)
--   12-Apr-2025 (this version - Risc2cpp)
--
-- COPYRIGHT:
--   Copyright (C) Stephen Thompson, 2010 - 2011, 2025.
--
--   This file is part of Risc2cpp. Risc2cpp is distributed under the terms
--   of the Boost Software License, Version 1.0, the text of which
--   appears below.
--
--   Boost Software License - Version 1.0 - August 17th, 2003
--   
--   Permission is hereby granted, free of charge, to any person or organization
--   obtaining a copy of the software and accompanying documentation covered by
--   this license (the "Software") to use, reproduce, display, distribute,
--   execute, and transmit the Software, and to prepare derivative works of the
--   Software, and to permit third-parties to whom the Software is furnished to
--   do so, all subject to the following:
--
--   The copyright notices in the Software and this entire statement, including
--   the above license grant, this restriction and the following disclaimer,
--   must be included in all copies of the Software, in whole or in part, and
--   all derivative works of the Software, unless such copies or derivative
--   works are solely in the form of machine-executable object code generated by
--   a source language processor.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
--   SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
--   FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
--   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.


module Main where

import Risc2cpp.BasicBlock
import Risc2cpp.CodeGen
import Risc2cpp.ExtractCode
import Risc2cpp.LocalVarAlloc
import Risc2cpp.RiscVToIntermed
import Risc2cpp.Simplifier

import qualified Data.ByteString as B
import Data.Char
import Data.Elf
import Data.List
import qualified Data.Map as Map
import Data.Map (Map)
import Options.Applicative
import System.FilePath (takeFileName)
import System.IO

-- Command line options
data Options = Options
  { optimizationLevel :: Int
  , inputFilename :: String
  , outputHppFilename :: String
  , outputCppFilename :: String
  }

optParser :: Parser Options
optParser = Options
            <$> option auto
                    ( short 'O'
                    <> help "Optimization level (0, 1 or 2)"
                    <> showDefault
                    <> value 1
                    <> metavar "opt_level" )
            <*> strArgument
                    ( metavar "INPUT"
                    <> help "Input filename (must be a 32-bit RISC-V ELF executable)" )
            <*> strArgument
                    ( metavar "OUTPUT.hpp"
                    <> help "Output .hpp filename" )
            <*> strOption
                    ( metavar "OUTPUT.cpp"
                    <> help "Output .cpp filename" )

optParserInfo :: ParserInfo Options
optParserInfo = info (optParser <**> helper)
       ( fullDesc
         <> header "Convert a 32-bit RISC-V binary to C++ code" )

-- Main Function
main :: IO ()
main = do
  opts <- customExecParser (prefs showHelpOnEmpty) optParserInfo

  -- Read input file
  elfBytestring <- B.readFile (inputFilename opts)
  let elf = parseElf elfBytestring

  -- Extract code & data chunks, and potential indirect jump targets
  -- NB: indJumpTargets0 is unsorted & may contain duplicates.
  let (indJumpTargets0, codeChunks, dataChunks, programBreak) = extractCode elf

  -- Convert code chunks to Intermediate form
  let (allIndJumpTargets, intermediateCode) = riscVToIntermed indJumpTargets0 codeChunks

  -- Extract basic blocks
  let basicBlocks = findBasicBlocks allIndJumpTargets intermediateCode

  -- Run optimization passes
  let simplified = simplify (optimizationLevel opts) allIndJumpTargets basicBlocks

  -- Generate the C++ code
  let hppFilename = outputHppFilename opts
  let cppFilename = outputCppFilename opts
  let baseHppFilename = takeFileName hppFilename

  let withLocVars = Map.map allocLocalVars simplified
      (hppCode, cppCode) = codeGen baseHppFilename withLocVars allIndJumpTargets dataChunks (fromIntegral $ elfEntry elf) programBreak

  -- Save the results to the output files
  writeFile hppFilename (intercalate "\n" hppCode)
  writeFile cppFilename (intercalate "\n" cppCode)
